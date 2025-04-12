defmodule Constellation.Games.GameState do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Constellation.Repo
  alias Constellation.Games.Game
  alias Constellation.Games.Categories
  alias Constellation.Games.AIVerifier
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
        player_answers = Map.get(state.player_answers, state.current_round, %{})
        updated_player_answers = Map.put(player_answers, player_id, %{
          "session_id" => player_id,
          "name" => player_name,
          "answers" => answers
        })
        
        # Update game state with new player answers
        all_answers = Map.put(state.player_answers, state.current_round, updated_player_answers)
        
        state
        |> changeset(%{player_answers: all_answers})
        |> Repo.update()
    end
  end
  
  @doc """
  Get all player answers for the current round
  """
  def get_current_round_answers(game_id) do
    case get_game_state(game_id) do
      nil -> []
      state -> 
        round_answers = Map.get(state.player_answers, state.current_round, %{})
        Map.values(round_answers)
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
    case get_game_state(game_id) do
      nil ->
        {:error, :game_not_found}
        
      state ->
        if state.status != "verifying" do
          {:error, :round_not_in_verification}
        else
          # Get player answers for the current round
          player_answers = get_current_round_answers(game_id)
          
          # Verify answers using AI
          case AIVerifier.verify_round(
            state.current_letter, 
            state.current_categories, 
            player_answers, 
            state.stopper_id
          ) do
            {:ok, results} ->
              # Process verification results
              process_verification_results(game_id, results)
              
            {:error, reason} ->
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
    
    # Process each player's results
    Enum.each(results, fn player_result ->
      player_id = player_result["player_id"]
      
      # Process each category result
      Enum.each(player_result["category_results"], fn category_result ->
        category = category_result["category"]
        _answer = category_result["answer"]
        is_valid = category_result["is_valid"]
        points = category_result["points"]
        
        # Generate explanation text
        explanation = generate_explanation(category_result, player_result["is_stopper"], player_result["stopper_bonus"])
        
        # Find the existing round entry
        query = from re in Constellation.Games.RoundEntry,
          where: re.game_id == ^game_id and
                 re.player_id == ^player_id and
                 re.round_number == ^state.current_round and
                 re.category == ^category
        
        case Repo.one(query) do
          nil -> 
            # If no entry exists (shouldn't happen), create one
            Logger.warning("No round entry found for player #{player_id}, round #{state.current_round}, category #{category}")
          
          entry ->
            # Update the entry with verification results
            entry
            |> Constellation.Games.RoundEntry.changeset(%{
              score: points,
              verification_status: "completed",
              is_valid: is_valid,
              ai_explanation: explanation
            })
            |> Repo.update()
        end
      end)
      
      # Add stopper bonus if applicable
      if player_result["is_stopper"] && player_result["stopper_bonus"] > 0 do
        # Create a special entry for the stopper bonus
        Constellation.Games.RoundEntry.create_entry(%{
          player_id: player_id,
          game_id: game_id,
          round_number: state.current_round,
          letter: state.current_letter,
          category: "STOPPER_BONUS",
          answer: "Stopped the round with all valid answers",
          score: player_result["stopper_bonus"],
          verification_status: "completed",
          is_valid: true,
          ai_explanation: "Bonus points for stopping the round with all valid answers"
        })
      end
    end)
    
    # Update game state to indicate verification is complete
    {:ok, updated_state} = state
      |> changeset(%{status: "completed_verification"})
      |> Repo.update()
    
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
  end
  
  # Generate explanation text for a category result
  defp generate_explanation(category_result, _is_stopper, _stopper_bonus) do
    category = category_result["category"]
    answer = category_result["answer"]
    is_valid = category_result["is_valid"]
    is_unique = category_result["is_unique"]
    _points = category_result["points"]
    
    cond do
      is_nil(answer) || answer == "" ->
        "No answer provided for #{category}."
        
      !is_valid ->
        "Answer '#{answer}' for #{category} is invalid. It must start with the correct letter."
        
      is_unique ->
        "Answer '#{answer}' for #{category} is valid and unique. +2 points."
        
      is_valid && !is_unique ->
        "Answer '#{answer}' for #{category} is valid but not unique. +1 point."
        
      true ->
        "Answer '#{answer}' for #{category}."
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
