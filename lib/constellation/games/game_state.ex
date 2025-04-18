defmodule Constellation.Games.GameState do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Constellation.Repo
  alias Constellation.Games.Game
  alias Constellation.Games.Categories
  alias Constellation.Games.AIVerifier
  alias Constellation.Games.RoundEntry
  alias Constellation.Games.Player
  alias Constellation.Analytics # Added for Mixpanel tracking
  require Logger

  schema "game_states" do
    field :current_letter, :string
    field :current_round, :integer, default: 1
    field :round_stopped, :boolean, default: false
    field :current_categories, {:array, :string}, default: []
    field :status, :string, default: "in_progress" # in_progress, collecting, verifying, completed
    field :verified_answers_by_round, :map, default: %{} # Renamed from player_answers. Stores {round_num_str => {player_id => %{name: ..., answers: %{...}}}} after verification.
    field :current_round_submissions, :map, default: %{} # New field. Stores {player_id => answers_map} during collection phase.
    field :stopper_id, :string # Keep track of who stopped the round
    belongs_to :game, Game

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(game_state, attrs) do
    game_state
    |> cast(attrs, [
      :current_round, :current_letter, :round_stopped, :game_id,
      :current_categories, :status, :stopper_id,
      :verified_answers_by_round, :current_round_submissions # Updated fields
    ])
    |> validate_required([:current_round, :current_letter, :round_stopped, :game_id, :current_categories, :status])
    |> unique_constraint(:game_id)
  end

  @doc """
  Initialize game state for a new game
  """
  def initialize_game_state(game_id) do
    first_letter = generate_random_letter()
    initial_categories = Categories.select_initial_categories(5)

    changeset =
      %__MODULE__{}
      |> changeset(%{
        game_id: game_id,
        current_round: 1,
        current_letter: first_letter,
        round_stopped: false,
        current_categories: initial_categories,
        status: "in_progress",
        verified_answers_by_round: %{}, # Initialize renamed field
        current_round_submissions: %{}  # Initialize new field
      })

    # Attempt to insert, but do nothing if a game state with this game_id already exists
    changeset
    |> Repo.insert(on_conflict: :nothing, conflict_target: :game_id)

    # Regardless of insert outcome, fetch the current state to ensure consistency
    # Use get_game_state! to raise an error if fetching fails unexpectedly
    case get_game_state(game_id) do
      nil -> 
        # This should ideally not happen if insert succeeded or conflict occurred
        Logger.error("Failed to initialize or find game state for game_id: #{game_id} after insert attempt.")
        {:error, :not_found}
      state -> 
        {:ok, state}
    end
  end

  @doc """
  Get the current game state
  """
  def get_game_state(game_id) do
    Repo.get_by(__MODULE__, game_id: game_id)
  end

  @doc """
  Get the current game state, raising if not found
  """
  def get_game_state!(game_id) do
    case Repo.get_by(__MODULE__, game_id: game_id) do
      nil -> raise "GameState not found for game_id: #{game_id}"
      state -> state
    end
  end

  def get_current_round(game_id) do
    case get_game_state(game_id) do
      nil -> 1
      state -> state.current_round
    end
  end

  def get_current_letter(game_id) do
    case get_game_state(game_id) do
      nil -> generate_random_letter()
      state -> state.current_letter
    end
  end

  def is_round_stopped?(game_id) do
    case get_game_state(game_id) do
      nil -> false
      state -> state.round_stopped
    end
  end

  @doc """
  Update game state attributes.
  """
  def update_game_state(game_state, attrs) do
    game_state
    |> changeset(attrs)
    |> Repo.update!() # Using update! for simplicity, adjust error handling if needed
    |> case do
      {:ok, updated_state} ->
        {:ok, updated_state}
      error -> error
    end
  end

  @doc """
  Record a player's submitted answers for the current round during the collection phase.
  This is intended to be called transactionally or carefully to avoid race conditions if multiple players submit simultaneously.
  Consider using Ecto.Multi if updates become complex.
  """
  def record_player_submission(game_id, player_id, answers) do
    # Fetch the current state initially mainly to check existence and get round #
    case get_game_state(game_id) do
      nil ->
        Logger.error("Cannot record submission, GameState not found for game #{game_id}")
        {:error, :not_found}

      initial_state -> # We have an initial state, proceed with update attempt
        player_id_str = to_string(player_id)
        Logger.info("Attempting to record submission for player #{player_id_str} in game #{game_id}, round #{initial_state.current_round}")

        # --- Update Logic --- 
        # Fetch the *latest* state again right before updating to minimize race condition
        current_state = get_game_state!(game_id) # Use ! as we expect it to exist now

        # Merge the new submission into the *latest* submissions map
        current_submissions = current_state.current_round_submissions || %{}
        updated_submissions = Map.put(current_submissions, player_id_str, answers)

        Logger.debug("Merging submission for player #{player_id_str}. Current map size: #{map_size(current_submissions)}, Updated map size: #{map_size(updated_submissions)}")

        # Update the latest state with the merged submissions
        case current_state
             |> changeset(%{current_round_submissions: updated_submissions})
             |> Repo.update() do
          {:ok, final_state} ->
            Logger.info("Successfully recorded submission for player #{player_id_str}")
            # Track event
            Analytics.track_submission_received(final_state.game_id, player_id, final_state.current_round, map_size(answers))
            {:ok, final_state}
          {:error, changeset} ->
            Logger.error("Failed to record submission for player #{player_id_str}: #{inspect(changeset.errors)}")
            {:error, changeset}
        end
        # --- End Update Logic ---
    end
  end

  @doc """
  Get the verified answers for the current round (after verification is complete).
  """
  def get_current_round_answers(game_id) do
    case get_game_state(game_id) do
      nil ->
        Logger.warning("No game state found for game #{game_id} when getting round answers")
        %{}
      state ->
        Map.get(state.verified_answers_by_round, "#{state.current_round}", %{})
    end
  end

  @doc """
  Generates verification jobs for the collected submissions.
  Returns a map of {player_id, job_id}.
  This should be called after submissions are collected.
  """
  def generate_verification_jobs(game_state) do
    submissions = game_state.current_round_submissions
    letter = game_state.current_letter
    categories = game_state.current_categories

    Enum.map(submissions, fn {player_id, answers} ->
      # Optional: Fetch player name if needed by AI Verifier context, otherwise just pass ID
      # player = Repo.get(Constellation.Games.Player, player_id)
      # name = player.name

      job_id = AIVerifier.verify_answers(%{
        player_id: player_id,
        # player_name: name,
        letter: letter,
        categories: categories,
        answers: answers
      })
      {player_id, job_id}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Process verification results and update player scores using the captured context
  from the time verification was initiated.
  """
  def process_verification_results(game_id, results, round_context) do
    # The context now comes from round_context, not live state
    # state = get_game_state!(game_id) 
    current_round = round_context.current_round
    current_letter = round_context.current_letter
    current_categories = round_context.current_categories
    submissions = round_context.submissions # Use submissions from context
    stopper_id = round_context.stopper_id # Ensure stopper_id is in context

    Logger.info("Processing verification results for game #{game_id}, round #{current_round} (using captured context)")

    # Fetch all players associated with this game
    all_players = Constellation.Games.Player.list_players_for_game(game_id)
    
    # Create a map of session_id -> player for efficient lookup
    player_map = Enum.into(all_players, %{}, fn player -> {player.session_id, player} end)
    Logger.info("Found #{map_size(player_map)} players associated with game #{game_id}")

    # Convert results list to a map keyed by player_id for efficient lookup
    results_map = Enum.into(results, %{}, fn result -> 
      player_id = result["player_id"]
      Logger.debug("Processing result for player_id: #{player_id}")
      {player_id, result} 
    end)
    Logger.debug("Results map keys: #{inspect(Map.keys(results_map))}")

    # Get the submissions from the CONTEXT
    # submissions = state.current_round_submissions || %{} # OLD: reads live state
    Logger.info("Current round submissions from context: #{inspect(Map.keys(submissions))}")

    # Ensure all players have entries processed
    Enum.each(player_map, fn {session_id, player} ->
      # Try to find results for this player by session_id or numeric ID
      player_result = Map.get(results_map, session_id) ||
                      Map.get(results_map, "#{player.id}") ||
                      Map.get(results_map, player.id) ||
                      # Also try to find by player_id in the result
                      Enum.find_value(results, fn result -> 
                        if result["player_id"] == "#{player.id}" || 
                           result["player_id"] == session_id do
                          result
                        else
                          nil
                        end
                      end)
      
      # Check if this player has submissions IN THE CONTEXT
      player_submissions = Map.get(submissions, "#{player.id}") || 
                           Map.get(submissions, player.id) || 
                           %{}
      
      has_submissions = map_size(player_submissions) > 0
      
      Logger.debug("Looking for results for player #{player.name}: session_id=#{if player, do: player.session_id, else: "unknown"}, id=#{player.id}, found=#{player_result != nil}, has_submissions=#{has_submissions}")
      
      case player_result do
        nil ->
          # Player has no results from AI Verifier
          if has_submissions do
            # Player submitted answers but they weren't processed by the AI
            # Create entries based on their submissions
            Logger.warning("Player #{player.name} (#{session_id}) has submissions but no AI verification results. Creating entries from submissions.")
            Enum.each(player_submissions, fn {category, answer} ->
              # Only create entries for categories that match the current round CONTEXT
              if Enum.member?(current_categories, category) do
                # Simple validation - check if answer starts with the round letter from CONTEXT
                is_valid = String.length(answer) > 0 && 
                          String.first(String.downcase(answer)) == String.first(String.downcase(current_letter))
                
                upsert_round_entry(game_id, player.id, current_round, current_letter, category, %{
                  answer: answer,
                  score: if(is_valid, do: 1, else: 0),
                  verification_status: "completed",
                  is_valid: is_valid,
                  ai_explanation: if(is_valid, 
                    do: "Valid answer starting with #{current_letter}", 
                    else: "Invalid answer - must start with #{current_letter}")
                })
              end
            end)
          else
            # Player has no submissions and no results - ensure zero-score entries
            Logger.warning("Player #{player.name} (#{session_id}) has no submissions and no AI verification results. Ensuring zero-score entries.")
            # Pass context values instead of state
            ensure_zero_entries_for_player(game_id, player.id, current_round, current_letter, current_categories)
          end

          # Check if this player is the stopper and apply penalty if needed
          # Use stopper_id from context
          is_stopper? = session_id == stopper_id || "#{player.id}" == stopper_id
          if is_stopper? do
            Logger.info("Player #{player.name} is the stopper but has no verification results. Applying penalty.")
            # Pass context values instead of state
            apply_stopper_penalty(game_id, player.id, current_round, current_letter)
          end

        player_result ->
          # Player has results, process them
          Logger.info("Processing results for player #{player.name} (#{session_id})")
          
          # Check if all answers are valid
          has_valid_answers = Enum.any?(player_result["category_results"], & &1["is_valid"])
          all_valid? = Enum.all?(player_result["category_results"], & &1["is_valid"])
          Logger.info("Player #{player.name}: Has valid answers?: #{has_valid_answers}, All valid?: #{all_valid?}")

          # Process each category result
          Enum.each(player_result["category_results"], fn category_result ->
            category = category_result["category"]
            answer = category_result["answer"]
            is_valid = category_result["is_valid"]
            points = category_result["points"]

            Logger.debug("Player #{player.name} - Processing category #{category}, answer: #{answer}, valid: #{is_valid}, points: #{points}")

            # Generate explanation text
            explanation = generate_explanation(category_result, player_result["is_stopper"], player_result["stopper_bonus"])

            # Upsert the round entry (create if not exists, update if exists)
            # Pass context values instead of state
            upsert_round_entry(game_id, player.id, current_round, current_letter, category, %{
              answer: answer || "",
              score: points,
              verification_status: "completed",
              is_valid: is_valid,
              ai_explanation: explanation
            })
          end) # End category_results loop

          # --- Handle categories submitted but not in AI results ---
          # Fetch the player's original submissions again for this specific round from context
          # current_state_for_lookup = get_game_state!(game_id)
          player_submissions_in_round = Map.get(submissions || %{}, "#{player.id}", %{}) # Use context submissions

          submitted_categories = Map.keys(player_submissions_in_round)
          processed_categories = Enum.map(player_result["category_results"], &(&1["category"]))

          missed_categories = Enum.reject(submitted_categories, fn category ->
            category in processed_categories || String.starts_with?(category, "_unused_")
          end)

          if Enum.any?(missed_categories) do
            Logger.warning("Player #{player.name} submitted categories not found in AI results: #{inspect(missed_categories)}. Marking as invalid.")
            Enum.each(missed_categories, fn category ->
              original_answer = Map.get(player_submissions_in_round, category, "")
              # Check if an entry already exists before upserting, avoid double entries
              # Pass context values
              existing_entry = Constellation.Games.RoundEntry.get_entry(player.id, game_id, current_round, category)

              if existing_entry do
                 Logger.info("Updating existing entry for missed category: #{category} for player #{player.id}")
                 upsert_round_entry(game_id, player.id, current_round, current_letter, category, %{
                   answer: original_answer,
                   score: 0,
                   verification_status: "completed",
                   is_valid: false,
                   ai_explanation: "Submitted answer not processed or deemed invalid by AI."
                 })
              else
                 # This case should be less common if submissions imply entry creation, but handles edge cases
                 Logger.warning("No existing entry found for submitted but missed category: #{category}. Creating new invalid entry.")
                 upsert_round_entry(game_id, player.id, current_round, current_letter, category, %{
                   answer: original_answer,
                   score: 0,
                   verification_status: "completed",
                   is_valid: false,
                   ai_explanation: "Submitted answer not processed or deemed invalid by AI."
                 })
              end
            end)
          end
          # --- End handle missed categories ---

          # --- Stopper Bonus/Penalty Logic ---
          # Check if THIS player is the stopper based on CONTEXT stopper_id
          is_stopper? = player.session_id == stopper_id || "#{player.id}" == stopper_id
          
          if is_stopper? do
            Logger.info("Player #{player.name} (#{player.id}) is the stopper. All valid: #{all_valid?}, Has valid: #{has_valid_answers}")
            entry_params = cond do
              # All answers are valid - give full bonus
              all_valid? -> 
                %{
                  answer: "Stopped round with all valid answers",
                  score: 2,
                  ai_explanation: "+2 bonus for valid stop with all valid answers"
                }
              # At least one valid answer - no bonus or penalty
              has_valid_answers -> 
                %{
                  answer: "Stopped round with some valid answers",
                  score: 0,
                  ai_explanation: "No bonus or penalty - some answers were valid"
                }
              # No valid answers - apply penalty
              true -> 
                %{
                  answer: "Stopped round with no valid answers",
                  score: -2,
                  ai_explanation: "-2 penalty for stopping with no valid answers"
                }
            end
            
            case Constellation.Games.RoundEntry.create_entry(Map.merge(%{
              player_id: player.id,
              game_id: game_id,
              round_number: current_round, # Use context round number
              letter: current_letter, # Use context letter
              category: "STOPPER_BONUS",
              verification_status: "completed",
              is_valid: all_valid?
            }, entry_params)) do
              {:ok, entry} -> 
                Logger.info("Created stopper entry ID #{entry.id} with score #{entry_params.score}")
              {:error, err} -> 
                Logger.error("Failed to create stopper entry: #{inspect(err)}")
            end
          end
          # --- End Stopper Logic ---
      end # End case Map.get
    end) # End player_ids loop

    # Update game state to indicate verification is complete
    # We might need to fetch the state here IF we need to update it
    # But this function's primary role is processing results and saving RoundEntries
    # Let's keep the state update separate for now, perhaps triggered elsewhere after this finishes.
    # Logger.info("Updating game state to completed_verification for game #{game_id}")
    # state
    # |> change(%{status: "completed_verification"})
    # |> Repo.update()

    Logger.info("Finished processing verification results for game #{game_id}, round #{current_round}")
    
  end

  @doc """
  Updates the game state to indicate that the round has been stopped.
  """
  def complete_verification(game_id) do
    case get_game_state(game_id) do
      nil ->
        Logger.error("GameState not found for game_id: #{game_id}")
        {:error, :game_not_found}
      state ->
        if state.status == "verifying" do
          Logger.info("Updating game state to completed_verification for game #{game_id}")

          state
          |> changeset(%{status: "completed_verification"})
          |> Repo.update()
          |> case do
               {:ok, updated_state} ->
                 # Broadcast status update
                 Phoenix.PubSub.broadcast(
                   Constellation.PubSub,
                   "game:#{game_id}",
                   {:round_update, %{
                     status: "completed_verification",
                     round: updated_state.current_round,
                     letter: updated_state.current_letter,
                     categories: updated_state.current_categories
                   }}
                 )

                 {:ok, updated_state}
               error -> error
             end
        else
          Logger.warning("Game is not in verifying state, cannot complete verification: #{game_id}")
          {:error, :wrong_state}
        end
    end
  end

  # Helper function to ensure zero-score entries exist for a player who didn't get results
  # Accepts context values instead of state
  defp ensure_zero_entries_for_player(game_id, player_id, current_round, current_letter, current_categories) do
    Logger.info("Ensuring zero-score entries for player #{player_id}, round #{current_round}")
    # Get this player's actual submissions from the game state
    game_state = get_game_state(game_id)
    player_submissions = if game_state && game_state.current_round_submissions do
      Map.get(game_state.current_round_submissions, to_string(player_id)) ||
      Map.get(game_state.current_round_submissions, player_id) ||
      %{}
    else
      %{}
    end

    Enum.each(current_categories, fn category ->
      # Skip _unused_ categories
      unless String.starts_with?(category, "_unused_") do
          # Fist check if an entry already exists for this player, category, and round
          existing_entry = Constellation.Games.RoundEntry.get_entry(player_id, game_id, current_round, category)

          # Get the actual answer submitted if it exists
          answer = Map.get(player_submissions, category, "<blank>")

          # Only create a blank entry if not entry exists
          if is_nil(existing_entry) do
            upsert_round_entry(game_id, player_id, current_round, current_letter, category, %{
              answer: answer,
              score: 0,
              verification_status: "completed",
              is_valid: false,
              ai_explanation: "Submitted answer not processed or deemed invalid by AI."
            })
            end
        end
    end)
  end

  # Helper function to apply penalty to the stopper if they have no verification results
  # Accepts context values instead of state
  defp apply_stopper_penalty(game_id, player_id, current_round, current_letter) do
    Logger.info("Applying penalty to stopper player #{player_id}, round #{current_round}")
    # Use context values
    upsert_round_entry(game_id, player_id, current_round, current_letter, "STOPPER_PENALTY", %{
      answer: "Stopped round with no valid answers",
      score: -2,
      verification_status: "completed",
      is_valid: false,
      ai_explanation: "-2 penalty for stopping with no valid answers"
    })
  end

  # Helper function to find or create a round entry and update it
  # Accepts context values instead of state
  defp upsert_round_entry(game_id, player_id, current_round, current_letter, category, data) do
    require Logger
    # round_number = state.current_round # OLD
    round_number = current_round # NEW

    Logger.info("""
    Upserting round entry:
      Game ID: #{inspect(game_id)}
      Player ID: #{inspect(player_id)}
      Round Number: #{inspect(round_number)}
      Category: #{inspect(category)}
      Data: #{inspect(data)}
    """)

    query = from re in Constellation.Games.RoundEntry,
      where: re.game_id == ^game_id and
             re.player_id == ^player_id and
             re.round_number == ^round_number and # Use context round
             re.category == ^category

    case Repo.all(query) do
      [] ->
        Logger.info("No existing round entry found. Creating a new one.")
        %Constellation.Games.RoundEntry{}
        |> Constellation.Games.RoundEntry.changeset(Map.merge(%{
          game_id: game_id,
          player_id: player_id,
          round_number: round_number, # Use context round
          category: category,
          letter: current_letter, # Use context letter
          verification_status: "completed",
          is_valid: false,
          score: 0 # Default score
        }, data))
        |> Repo.insert()
        |> case do
          {:ok, entry} ->
            Logger.info("Successfully inserted round entry ID #{entry.id} for player #{player_id}, category #{category}, score #{entry.score}")
            {:ok, entry} # Return the original success tuple
          {:error, changeset} ->
            Logger.error("Failed to insert round entry for player #{player_id}, category #{category}. Error: #{inspect(changeset)}")
            {:error, changeset} # Return the original error tuple
        end

      [existing_entry | duplicates] ->
        # Log if we found duplicates
        if duplicates != [] do
          Logger.warning("Found #{length(duplicates) + 1} entries for player #{player_id}, category #{category}. Using first one and ignoring duplicates.")

          # Optional: Delete duplicates to prevent this issue in the future
          Enum.each(duplicates, fn dup ->
            Logger.info("Deleting duplicate entry ID #{dup.id}")
            Repo.delete(dup)
          end)
        end

        Logger.info("Updating existing round entry: #{inspect(existing_entry)}")

        # Ensure blank answers are stored as "<blank>" consistent with create
        updated_data = 
          if Map.get(data, :answer) == "" do
            Map.put(data, :answer, "<blank>")
          else
            data
          end

        existing_entry
        |> Constellation.Games.RoundEntry.changeset(updated_data)
        |> Repo.update()
        |> case do
          {:ok, entry} ->
            Logger.info("Successfully updated round entry ID #{entry.id} for player #{player_id}, category #{category}, score #{entry.score}")
            {:ok, entry} # Return the original success tuple
          {:error, changeset} ->
            Logger.error("Failed to update round entry for player #{player_id}, category #{category} (ID: #{existing_entry.id}). Error: #{inspect(changeset)}")
            {:error, changeset} # Return the original error tuple
        end
    end
  end

  # Helper function to generate explanation text for a category result
  defp generate_explanation(category_result, _is_stopper, _stopper_bonus) do
    # If the AI provided an explanation, use it
    if Map.has_key?(category_result, "explanation") do
      category_result["explanation"]
    else
      # Otherwise, generate a default explanation
      category = category_result["category"]
      answer = category_result["answer"]
      is_valid = category_result["is_valid"]
      points = category_result["points"]
      
      cond do
        is_nil(answer) || answer == "" ->
          "No answer provided for #{category}."
          
        !is_valid ->
          "Answer '#{answer}' for #{category} is invalid. It does not appear to be a valid entry for this category."
          
        is_valid ->
          "Answer '#{answer}' for #{category} is valid. +#{points} points."
          
        true ->
          "Answer '#{answer}' for #{category}."
      end
    end
  end

  @doc """
  Advance the game to the next round or mark as completed.
  """
  def advance_to_next_round(game_id) do
    case get_game_state(game_id) do
      nil ->
        initialize_game_state(game_id)
      state ->
        next_round_number = state.current_round + 1
        next_letter = generate_random_letter()
        next_categories = Categories.update_categories_for_next_round(state.current_categories)

        # Check if game should end (e.g., max rounds reached)
        # if next_round_number > MAX_ROUNDS do ... end

        Logger.info("Advancing game #{game_id} to round #{next_round_number}")

        state
        |> changeset(%{
          current_round: next_round_number,
          current_letter: next_letter,
          current_categories: next_categories,
          round_stopped: false,
          status: "in_progress",
          stopper_id: nil,
          current_round_submissions: %{} # Ensure submissions are cleared
        })
        |> Repo.update()
        |> case do
          {:ok, updated_state} ->
            # Fetch players associated with the game_id
            players = Constellation.Games.Player.list_players_for_game(game_id)
            
            # Track event for each fetched player
            Enum.each(players, fn player ->
              Analytics.track_round_started(updated_state.game_id, player.id, updated_state.current_round, updated_state.current_letter)
            end)

            # Broadcast round update with new round info
            Phoenix.PubSub.broadcast(
              Constellation.PubSub,
              "game:#{game_id}",
              {:round_update, %{
                round: updated_state.current_round,
                letter: updated_state.current_letter,
                categories: updated_state.current_categories,
                status: updated_state.status
              }}
            )

            # Also broadcast game_started event to ensure all players get the countdown
            Phoenix.PubSub.broadcast(
              Constellation.PubSub,
              "game:#{game_id}",
              {:game_started, %{
                round: updated_state.current_round,
                letter: updated_state.current_letter,
                categories: updated_state.current_categories
              }}
            )

            {:ok, updated_state}

          error -> error
        end
        # Return result tuple
    end
  end

  @doc """
  Get the current categories for a game
  """
  def get_current_categories(game_id) do
    case get_game_state(game_id) do
      nil -> Categories.select_initial_categories(5)
      state -> state.current_categories
    end
  end
  
  @doc """
  Get the game status (in_progress, verifying, completed)
  """
  def get_game_status(game_id) do
    case get_game_state(game_id) do
      nil -> "in_progress"
      state -> state.status
    end
  end
  
  @doc """
  Get the player who stopped the current round
  """
  def get_round_stopper(game_id) do
    case get_game_state(game_id) do
      nil -> nil
      state -> state.stopper_id
    end
  end

  @doc """
  Mark the current round as stopped
  """
  def mark_round_as_stopped(game_id, stopper_id) do
    case get_game_state(game_id) do
      nil -> 
        # Initialize game state if it doesn't exist
        initialize_game_state(game_id)
        
      state -> 
        # Update the existing state
        Logger.info("Marking round as stopped for game #{game_id}, stopper_id: #{stopper_id}")
        
        # Update the game state
        state
        |> changeset(%{
          round_stopped: true, 
          status: "verifying",
          stopper_id: stopper_id
        })
        |> Repo.update()
        |> case do
          {:ok, updated_state} ->
            {:ok, updated_state}
          error -> error
        end
    end
  end

  @doc """
  Verify the current round using AI
  """
  @doc """
  Verify the current round using AI
  """
  def verify_round(game_id) do
    Logger.info("Starting verification for game #{game_id}")

    # Ensure HTTPoison is loaded
    {:ok, _} = Application.ensure_all_started(:httpoison)
    Logger.info("HTTPoison application started")

    case get_game_state(game_id) do
      nil ->
        Logger.error("Game state not found for game #{game_id}")
        {:error, :game_not_found}

      state ->
        if state.status != "verifying" do
          Logger.warning("Game #{game_id} not in verification state (current status: #{state.status})")
          {:error, :round_not_in_verification}
        else
          Logger.info("Verifying round #{state.current_round} for game #{game_id}, letter: #{state.current_letter}")

          # CAPTURE CONTEXT HERE
          round_context = %{
            current_round: state.current_round,
            current_letter: state.current_letter,
            current_categories: state.current_categories,
            submissions: state.current_round_submissions || %{},
            stopper_id: state.stopper_id
          }

          # Get entries from the database for this round
          round_entries = Constellation.Games.RoundEntry.get_entries_for_round(game_id, state.current_round)

          # Group entries by player
          entries_by_player = Enum.group_by(round_entries, fn entry -> entry.player_id end)

          # Create a list to hold player answers
          db_player_answers = Enum.map(entries_by_player, fn {player_id, entries} ->
            # Find the player
            player = try do
              Constellation.Games.Player.get_player!(player_id)
            rescue
              _ -> nil
            end

            player_name = if player, do: player.name, else: "Player #{player_id}"
            player_session_id = if player, do: player.session_id, else: to_string(player_id)

            # Create a map of category -> answer from database entries
            answers = Enum.reduce(entries, %{}, fn entry, acc ->
              # Skip internal categories and stopper bonus
              if !String.starts_with?(entry.category, "_unused_") && entry.category != "STOPPER_BONUS" do
                Map.put(acc, entry.category, entry.answer)
              else
                acc
              end
            end)

            Logger.debug("Database answers for player #{player_name}: #{inspect(answers)}")

            # Return the player answer structure
            %{
              "session_id" => player_session_id,
              "name" => player_name,
              "answers" => answers
            }
          end)

          # Also get answers from the in-memory submissions as backup
          memory_player_answers = Enum.map(round_context.submissions, fn {player_id_str, answers} ->
            # Find the player to get their name
            player = try do
              player_id = String.to_integer(player_id_str)
              Constellation.Games.Player.get_player!(player_id)
            rescue
              _ -> nil
            end

            player_name = if player, do: player.name, else: "Player #{player_id_str}"

            Logger.debug("Memory answers for player #{player_name}: #{inspect(answers)}")

            # Return the player answer structure
            %{
              "session_id" => player_id_str,
              "name" => player_name,
              "answers" => answers
            }
          end)

          # Merge the answers, preferring database entries over memory entries
          # First, create a map of session_id -> answers for easy lookup
          memory_answers_map = Enum.into(memory_player_answers, %{}, fn player ->
            {player["session_id"], player}
          end)

          # For each DB player, check if they have memory entries too
          player_answers = Enum.map(db_player_answers, fn db_player ->
            session_id = db_player["session_id"]
            memory_player = Map.get(memory_answers_map, session_id)

            # If player has both DB and memory entries, merge them, preferring DB
            # If player only has DB entries, use those
            if memory_player do
              # Remove this player from the memory map so we don't duplicate
              memory_answers_map = Map.delete(memory_answers_map, session_id)

              # Merge answers, preferring DB entries
              merged_answers = Map.merge(memory_player["answers"], db_player["answers"])
              %{db_player | "answers" => merged_answers}
            else
              db_player
            end
          end)

          # Add any memory-only players
          player_answers = player_answers ++ Map.values(memory_answers_map)

          Logger.info("Found #{length(player_answers)} player answer sets for verification")

          # Verify answers using AI
          Logger.info("Calling AI verifier with #{length(state.current_categories)} categories")
          case AIVerifier.verify_round(
                 round_context.current_letter,
                 round_context.current_categories,
                 player_answers,
                 round_context.stopper_id
               ) do
            {:ok, results} ->
              Logger.info("AI verification successful, processing results for round #{round_context.current_round}")
              # Process verification results WITH CONTEXT
              process_verification_results(game_id, results, round_context)

              # Update game state to indicate verification is complete
              complete_verification(game_id)

              # Return success, perhaps indicating the round number processed
              {:ok, round_context.current_round}

            {:error, reason} ->
              Logger.error("AI verification failed for round #{round_context.current_round}: #{inspect(reason)}")
              {:error, reason}
          end
        end
    end
  end
  defp generate_random_letter do
    <<Enum.random(?A..?Z)>>
  end
end