defmodule Constellation.Games.GameState do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Constellation.Repo
  alias Constellation.Games.Game
  alias Constellation.Games.Categories
  alias Constellation.Games.AIVerifier
  alias Constellation.Games.RoundEntry
  require Logger

  schema "game_states" do
    field :current_letter, :string
    field :current_round, :integer, default: 1
    field :round_stopped, :boolean, default: false
    field :current_categories, {:array, :string}, default: []
    field :status, :string, default: "in_progress" # in_progress, verifying, completed
    field :player_answers, :map, default: %{}
    field :stopper_id, :string
    belongs_to :game, Game

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(game_state, attrs) do
    game_state
    |> cast(attrs, [:current_round, :current_letter, :round_stopped, :game_id, 
                   :current_categories, :status, :player_answers, :stopper_id])
    |> validate_required([:current_round, :current_letter, :round_stopped, :game_id, :current_categories, :status])
    |> unique_constraint(:game_id)
  end
  
  @doc """
  Initialize game state for a new game
  """
  def initialize_game_state(game_id) do
    # Generate a random letter for the first round
    first_letter = generate_random_letter()
    
    # Select initial categories
    initial_categories = Categories.select_initial_categories(5)
    
    # Create the game state
    %__MODULE__{}
    |> changeset(%{
      game_id: game_id,
      current_round: 1,
      current_letter: first_letter,
      round_stopped: false,
      current_categories: initial_categories,
      status: "in_progress",
      player_answers: %{}
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
  Get the current round for a game
  """
  def get_current_round(game_id) do
    case get_game_state(game_id) do
      nil -> 1
      state -> state.current_round
    end
  end
  
  @doc """
  Get the current letter for a game
  """
  def get_current_letter(game_id) do
    case get_game_state(game_id) do
      nil -> generate_random_letter()
      state -> state.current_letter
    end
  end
  
  @doc """
  Check if the current round has been stopped
  """
  def is_round_stopped?(game_id) do
    case get_game_state(game_id) do
      nil -> false
      state -> state.round_stopped
    end
  end
  
  @doc """
  Mark the current round as stopped
  """
  def mark_round_as_stopped(game_id, stopper_id) do
    case get_game_state(game_id) do
      nil -> 
        # Initialize game state if it doesn't exist
        {:ok, state} = initialize_game_state(game_id)
        state
        
      state -> 
        # Update the existing state without broadcasting - PubSub is now handled by LiveView
        Logger.info("Marking round as stopped for game #{game_id}, stopper_id: #{stopper_id}")
        
        # First, load all player answers from the database to ensure they're in the game state
        round_entries = Constellation.Games.RoundEntry.get_entries_for_round(game_id, state.current_round)
        
        # Group entries by player
        player_answers_map = round_entries
          |> Enum.group_by(fn entry -> entry.player_id end)
          |> Enum.map(fn {player_id, entries} -> 
            # Find player name from the player association
            player_name = case Enum.at(entries, 0) do
              nil -> "Unknown Player"
              entry -> 
                if entry.player && entry.player.name do
                  entry.player.name
                else
                  "Player #{player_id}"
                end
            end
            
            # Convert entries to a map of category -> answer
            answers = Enum.reduce(entries, %{}, fn entry, acc ->
              Map.put(acc, entry.category, entry.answer)
            end)
            
            # Return the player answer structure
            {player_id, %{
              "session_id" => player_id,
              "name" => player_name,
              "answers" => answers
            }}
          end)
          |> Enum.into(%{})
        
        # Update the player_answers field for the current round
        current_round_str = "#{state.current_round}"
        updated_player_answers = Map.put(state.player_answers || %{}, current_round_str, player_answers_map)
        
        Logger.info("Loaded #{map_size(player_answers_map)} player answer sets from database for verification")
        
        result = state
        |> changeset(%{
          round_stopped: true, 
          status: "verifying",
          stopper_id: stopper_id,
          player_answers: updated_player_answers
        })
        |> Repo.update()
        
        case result do
          {:ok, updated_state} ->
            Logger.info("Successfully updated game state: round_stopped=#{updated_state.round_stopped}, status=#{updated_state.status}")
            result
          {:error, changeset} ->
            Logger.error("Failed to update game state: #{inspect(changeset.errors)}")
            result
        end
    end
  end
  
  @doc """
  Record a player's answers for the current round
  """
  def record_player_answers(game_id, player_id, player_name, answers, stopped \\ false) do
    case get_game_state(game_id) do
      nil ->
        {:error, :game_not_found}
        
      state ->
        # If the player stopped the round, mark it as stopped
        state = if stopped and not state.round_stopped do
          {:ok, updated_state} = mark_round_as_stopped(game_id, player_id)
          updated_state
        else
          state
        end
        
        # Update player answers
        player_answers = Map.get(state.player_answers, "#{state.current_round}", %{})
        updated_player_answers = Map.put(player_answers, player_id, %{
          "session_id" => player_id,
          "name" => player_name,
          "answers" => answers
        })
        
        # Update game state with new player answers
        all_answers = Map.put(state.player_answers, "#{state.current_round}", updated_player_answers)
        
        Logger.info("Recording answers for player #{player_id} in game #{game_id}, round #{state.current_round}")
        Logger.debug("Current player_answers before update: #{inspect(state.player_answers)}")
        Logger.debug("Updated player_answers for storage: #{inspect(all_answers)}")
        
        result = state
        |> changeset(%{player_answers: all_answers})
        |> Repo.update()
        
        case result do
          {:ok, updated_state} ->
            Logger.info("Successfully updated player answers in game state")
            {:ok, updated_state}
          {:error, changeset} ->
            Logger.error("Failed to update player answers: #{inspect(changeset.errors)}")
            {:error, changeset}
        end
    end
  end
  
  @doc """
  Get all player answers for the current round
  """
  def get_current_round_answers(game_id) do
    case get_game_state(game_id) do
      nil -> 
        Logger.warning("No game state found for game #{game_id} when getting round answers")
        []
      state -> 
        round_key = "#{state.current_round}"
        round_answers = Map.get(state.player_answers, round_key, %{})
        Logger.debug("Retrieved player_answers for round #{round_key}: #{inspect(round_answers)}")
        
        answers = Map.values(round_answers)
        Logger.debug("Extracted #{length(answers)} player answer sets")
        answers
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
          
          # Get player answers for the current round
          player_answers = get_current_round_answers(game_id)
          Logger.info("Found #{length(player_answers)} player answer sets for verification")
          Logger.debug("Player answers for verification: #{inspect(player_answers)}")
          Logger.debug("Categories for verification: #{inspect(state.current_categories)}")
          Logger.debug("Stopper ID for verification: #{inspect(state.stopper_id)}")
          
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
  
  @doc """
  Process verification results and update player scores
  """
  def process_verification_results(game_id, results) do
    # Get the current game state to get round number and letter
    state = get_game_state(game_id)

    Logger.info("Processing verification results for game #{game_id}, round #{state.current_round}, letter #{state.current_letter}")
    Logger.info("Received #{length(results)} player results sets from AI Verifier")

    # Fetch all players associated with this game
    all_players = Constellation.Games.Player.list_players_for_game(game_id)
    # Create a map of session_id -> player for efficient lookup
    player_map = Enum.into(all_players, %{}, fn player -> {player.session_id, player} end)
    Logger.info("Found #{map_size(player_map)} players associated with game #{game_id}")
    Logger.debug("Player map: #{inspect(player_map, pretty: true)}")

    # Convert results list to a map keyed by player_id for efficient lookup
    results_map = Enum.into(results, %{}, fn result -> 
      player_id = result["player_id"]
      Logger.debug("Processing result for player_id: #{player_id}")
      {player_id, result} 
    end)
    Logger.debug("Results map keys: #{inspect(Map.keys(results_map))}")

    # Ensure all players have entries processed
    Enum.each(player_map, fn {session_id, player} ->
      # Try to find results for this player by session_id or numeric ID
      player_result = Map.get(results_map, session_id) || 
                      Map.get(results_map, "#{player.id}") ||
                      Map.get(results_map, player.id)
      
      Logger.debug("Looking for results for player #{player.name}: session_id=#{session_id}, id=#{player.id}, found=#{player_result != nil}")
      
      case player_result do
        nil ->
          # Player has no results from AI Verifier - ensure zero-score entries
          Logger.warning("Player #{player.name} (#{session_id}) has no results from AI Verifier. Ensuring zero-score entries.")
          ensure_zero_entries_for_player(game_id, player.id, state)

        player_result ->
          # Player has results, process them
          Logger.info("Processing results for player #{player.name} (#{session_id})")
          # Log the full player result for debugging
          Logger.debug("Full player result: #{inspect(player_result)}")
          
          # Check if all answers are valid
          all_valid = Enum.all?(player_result["category_results"], fn result -> result["is_valid"] end)
          Logger.info("Player #{player.name}: All answers valid? #{all_valid}")

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

          # Add stopper bonus if applicable
          is_stopper = player_result["is_stopper"]
          stopper_bonus = player_result["stopper_bonus"] || 0 # Default bonus to 0 if nil

          Logger.info("Player #{player.name}: Checking stopper bonus. is_stopper=#{is_stopper}, all_answers_valid=#{all_valid}, stopper_bonus=#{stopper_bonus}")

          if is_stopper && stopper_bonus > 0 do
            Logger.info("Adding stopper bonus of #{stopper_bonus} points for player #{player.name}")

            # Create a special entry for the stopper bonus
            case RoundEntry.create_entry(%{
              player_id: player.id,
              game_id: game_id,
              round_number: state.current_round,
              letter: state.current_letter,
              category: "STOPPER_BONUS",
              answer: "Stopped the round with all valid answers",
              score: stopper_bonus,
              verification_status: "completed",
              is_valid: true,
              ai_explanation: "Bonus points for stopping the round with all valid answers"
            }) do
              {:ok, bonus_entry} ->
                Logger.info("Successfully created stopper bonus entry ID #{bonus_entry.id} for player #{player.name}")

              {:error, failed_changeset} ->
                Logger.error("Failed to create stopper bonus entry for player #{player.name}: #{inspect(failed_changeset.errors)}")
            end
          else
            if is_stopper do
              Logger.info("Player #{player.name} is stopper, but bonus is not positive (#{stopper_bonus}). No bonus entry created.")
            end
          end
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
      upsert_round_entry(game_id, player_id, state, category, %{
        answer: "<blank>",  # Use "<blank>" instead of empty string
        score: 0,
        verification_status: "completed",
        is_valid: false,
        ai_explanation: "No answer submitted or processed for this category."
      })
    end)
  end

  # Helper function to find or create a round entry and update it
  defp upsert_round_entry(game_id, player_id, state, category, data) do
    query = from re in RoundEntry,
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

        case RoundEntry.create_entry(entry_data) do
          {:ok, new_entry} ->
            Logger.info("Created missing round entry ID #{new_entry.id} for player #{player_id}, category #{category} with score #{data[:score]}")
          {:error, err} ->
            Logger.error("Failed to create missing round entry for player #{player_id}, category #{category}: #{inspect(err)}")
        end

      entry ->
        # Entry exists, update it
        Logger.info("Updating entry ID #{entry.id} for player #{player_id}, category #{category} with score #{data[:score]}")
        changeset = RoundEntry.changeset(entry, data)

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
  Advance to the next round
  """
  def advance_to_next_round(game_id) do
    case get_game_state(game_id) do
      nil ->
        # Initialize game state if it doesn't exist
        initialize_game_state(game_id)
        
      state ->
        # Generate a new random letter
        next_letter = generate_random_letter()
        
        # Update categories for the next round
        next_categories = Categories.update_categories_for_next_round(state.current_categories)
        
        # Update the game state
        {:ok, updated_state} = state
          |> changeset(%{
            current_round: state.current_round + 1,
            current_letter: next_letter,
            round_stopped: false,
            current_categories: next_categories,
            status: "in_progress",
            stopper_id: nil
          })
          |> Repo.update()
          
        # Broadcast round update with new round info
        Phoenix.PubSub.broadcast(
          Constellation.PubSub,
          "game:#{game_id}",
          {:round_update, %{
            round: updated_state.current_round,
            letter: updated_state.current_letter,
            categories: updated_state.current_categories,
            status: updated_state.status,
            results: nil
          }}
        )
        
        {:ok, updated_state}
    end
  end
  
  # Generate a random letter
  defp generate_random_letter do
    ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", 
     "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"]
    |> Enum.random()
  end
end
