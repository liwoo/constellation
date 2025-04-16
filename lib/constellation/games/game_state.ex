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
    |> Repo.insert()
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
  Process verification results and update player scores
  """
  def process_verification_results(game_id, results) do
    Logger.info("Processing verification results for game #{game_id}")
    
    # Get the current game state
    state = get_game_state!(game_id)
    
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

    # Get the submissions from the game state
    submissions = state.current_round_submissions || %{}
    Logger.info("Current round submissions: #{inspect(Map.keys(submissions))}")

    # Ensure all players have entries processed
    Enum.each(player_map, fn {session_id, player} ->
      # Try to find results for this player by session_id or numeric ID
      player_result = Map.get(results_map, session_id) ||
                      Map.get(results_map, "#{player.id}") ||
                      Map.get(results_map, player.id) ||
                      # Also try to find by player_id in the result
                      Enum.find_value(results, fn result -> 
                        if result["player_id"] == "#{player.id}" || 
                           result["session_id"] == session_id do
                          result
                        else
                          nil
                        end
                      end)
      
      # Check if this player has submissions
      player_submissions = Map.get(submissions, "#{player.id}") || 
                           Map.get(submissions, player.id) || 
                           %{}
      
      has_submissions = map_size(player_submissions) > 0
      
      Logger.debug("Looking for results for player #{player.name}: session_id=#{session_id}, id=#{player.id}, found=#{player_result != nil}, has_submissions=#{has_submissions}")
      
      case player_result do
        nil ->
          # Player has no results from AI Verifier
          if has_submissions do
            # Player submitted answers but they weren't processed by the AI
            # Create entries based on their submissions
            Logger.warning("Player #{player.name} (#{session_id}) has submissions but no AI verification results. Creating entries from submissions.")
            Enum.each(player_submissions, fn {category, answer} ->
              # Only create entries for categories that match the current round
              if Enum.member?(state.current_categories, category) do
                # Simple validation - check if answer starts with the round letter
                is_valid = String.length(answer) > 0 && 
                          String.first(String.downcase(answer)) == String.first(String.downcase(state.current_letter))
                
                upsert_round_entry(game_id, player.id, state, category, %{
                  answer: answer,
                  score: if(is_valid, do: 1, else: 0),
                  verification_status: "completed",
                  is_valid: is_valid,
                  ai_explanation: if(is_valid, 
                    do: "Valid answer starting with #{state.current_letter}", 
                    else: "Invalid answer - must start with #{state.current_letter}")
                })
              end
            end)
          else
            # Player has no submissions and no results - ensure zero-score entries
            Logger.warning("Player #{player.name} (#{session_id}) has no submissions and no AI verification results. Ensuring zero-score entries.")
            ensure_zero_entries_for_player(game_id, player.id, state)
          end

          # Check if this player is the stopper and apply penalty if needed
          is_stopper? = session_id == state.stopper_id || "#{player.id}" == state.stopper_id
          if is_stopper? do
            Logger.info("Player #{player.name} is the stopper but has no verification results. Applying penalty.")
            apply_stopper_penalty(game_id, player.id, state)
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
            upsert_round_entry(game_id, player.id, state, category, %{
              answer: answer || "",
              score: points,
              verification_status: "completed",
              is_valid: is_valid,
              ai_explanation: explanation
            })
          end) # End category_results loop

          # --- Stopper Bonus/Penalty Logic ---
          # Check if THIS player is the stopper based on state.stopper_id
          is_stopper? = player.session_id == state.stopper_id || "#{player.id}" == state.stopper_id
          
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
              round_number: state.current_round,
              letter: state.current_letter,
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
    Logger.info("Updating game state to completed_verification for game #{game_id}")

    result = state
      |> changeset(%{status: "completed_verification"})
      |> Repo.update()
      
    case result do
      {:ok, updated_state} ->
        Logger.info("Successfully updated game state to #{updated_state.status}")

        # Broadcast round update with verification results
        Phoenix.PubSub.broadcast(
          Constellation.PubSub,
          "game:#{game_id}",
          {:round_update, %{
            round: updated_state.current_round,
            letter: updated_state.current_letter,
            categories: updated_state.current_categories,
            status: updated_state.status,
            results: results
          }}
        )

        {:ok, results}
      
      {:error, failed_changeset} ->
        Logger.error("Failed to update game state: #{inspect(failed_changeset.errors)}")
        {:error, :failed_to_update_game_state}
    end
  end

  # Helper function to ensure zero-score entries exist for a player who didn't get results
  defp ensure_zero_entries_for_player(game_id, player_id, state) do
    Logger.info("Ensuring zero-score entries for player #{player_id}, round #{state.current_round}")
    Enum.each(state.current_categories, fn category ->
      # First check if an entry already exists for this player, category, and round
      existing_entry = Constellation.Games.RoundEntry.get_entry(
        player_id,
        game_id,
        state.current_round,
        category
      )
      
      # Only create a blank entry if no entry exists
      if is_nil(existing_entry) do
        upsert_round_entry(game_id, player_id, state, category, %{
          answer: "<blank>",  # Use "<blank>" instead of empty string
          score: 0,
          verification_status: "completed",
          is_valid: false,
          ai_explanation: "No answer submitted or processed for this category."
        })
      end
    end)
  end

  # Helper function to apply penalty to the stopper if they have no verification results
  defp apply_stopper_penalty(game_id, player_id, state) do
    Logger.info("Applying penalty to stopper player #{player_id}, round #{state.current_round}")
    upsert_round_entry(game_id, player_id, state, "STOPPER_PENALTY", %{
      answer: "Stopped round with no valid answers",
      score: -2,
      verification_status: "completed",
      is_valid: false,
      ai_explanation: "-2 penalty for stopping with no valid answers"
    })
  end

  # Helper function to find or create a round entry and update it
  defp upsert_round_entry(game_id, player_id, state, category, data) do
    import Ecto.Query
    
    query = from re in Constellation.Games.RoundEntry,
      where: re.game_id == ^game_id and
             re.player_id == ^player_id and
             re.round_number == ^state.current_round and
             re.category == ^category

    case Repo.one(query) do
      nil ->
        # Entry doesn't exist, create it
        Logger.warning("No round entry found for player #{player_id}, round #{state.current_round}, category #{category}. Creating one.")
        entry_data = Map.merge(%{
          player_id: player_id,
          game_id: game_id,
          round_number: state.current_round,
          letter: state.current_letter,
          category: category
        }, data)

        case Constellation.Games.RoundEntry.create_entry(entry_data) do
          {:ok, new_entry} ->
            Logger.info("Created missing round entry ID #{new_entry.id} for player #{player_id}, category #{category} with score #{data[:score]}")
          {:error, err} ->
            Logger.error("Failed to create missing round entry for player #{player_id}, category #{category}: #{inspect(err)}")
        end

      entry ->
        # Entry exists, update it
        Logger.info("Updating entry ID #{entry.id} for player #{player_id}, category #{category} with score #{data[:score]}")
        changeset = Constellation.Games.RoundEntry.changeset(entry, data)

        case Repo.update(changeset) do
          {:ok, updated_entry} ->
            Logger.info("Successfully updated entry ID #{updated_entry.id}: status=#{updated_entry.verification_status}, valid=#{updated_entry.is_valid}, score=#{updated_entry.score}")

          {:error, failed_changeset} ->
            Logger.error("Failed to update entry ID #{entry.id} for player #{player_id}, category #{category}: #{inspect(failed_changeset.errors)}")
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
    end
  end

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
          
          # Get player answers from the current round submissions
          submissions = state.current_round_submissions || %{}
          
          # Convert to the format expected by the AIVerifier
          player_answers = Enum.map(submissions, fn {player_id_str, answers} ->
            # Find the player to get their name
            player = try do
              player_id = String.to_integer(player_id_str)
              Constellation.Games.Player.get_player(player_id)
            rescue
              _ -> nil
            end
            
            player_name = if player, do: player.name, else: "Player #{player_id_str}"
            
            Logger.debug("Looking for results for player #{player_name}: session_id=#{if player, do: player.session_id, else: "unknown"}, id=#{player_id_str}, found=#{!!player}")
            
            # Return the player answer structure
            %{
              "session_id" => player_id_str,
              "name" => player_name,
              "answers" => answers
            }
          end)
          
          Logger.info("Found #{length(player_answers)} player answer sets for verification")
          
          # Verify answers using AI
          Logger.info("Calling AI verifier with #{length(state.current_categories)} categories")
          case AIVerifier.verify_round(
            state.current_letter, 
            state.current_categories, 
            player_answers, 
            state.stopper_id
          ) do
            {:ok, results} ->
              Logger.info("AI verification successful, processing results")
              # Process verification results
              process_verification_results(game_id, results)
              
            {:error, reason} ->
              Logger.error("AI verification failed: #{inspect(reason)}")
              {:error, reason}
          end
        end
    end
  end

  defp generate_random_letter do
    <<Enum.random(?A..?Z)>>
  end
end
