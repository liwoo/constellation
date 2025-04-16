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
    case get_game_state(game_id) do
      nil ->
        Logger.error("Cannot record submission, GameState not found for game #{game_id}")
        {:error, :not_found}
      state ->
        # Add or overwrite the player's submission for the current round
        updated_submissions = Map.put(state.current_round_submissions || %{}, player_id, answers)

        Logger.info("Recording submission for player #{player_id} in game #{game_id}, round #{state.current_round}")
        Logger.debug("Submissions map updated: #{inspect(updated_submissions)}")

        state
        |> changeset(%{current_round_submissions: updated_submissions})
        |> Repo.update()
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
  Process the results from the AI verifier and update scores in RoundEntry.
  Returns the updated GameState.
  """
  def process_verification_results(game_state, verification_results) do
    game_id = game_state.game_id
    round_number = game_state.current_round
    letter = game_state.current_letter
    submissions = game_state.current_round_submissions
    all_players = Constellation.Games.get_players_for_game(game_id)

    Logger.info("Processing verification results for game #{game_id}, round #{round_number}, letter #{letter}")

    # 1. Update RoundEntry scores based on verification_results
    Enum.each(verification_results, fn {player_id, player_result} ->
      player_answers = Map.get(submissions, player_id, %{})
      RoundEntry.update_scores_from_verification(
        player_id,
        game_id,
        round_number,
        player_answers,
        player_result # This should be the map like %{"Category" => %{score: 10, reason: "Valid"}} 
      )
    end)

    # 2. Ensure zero entries exist for players who didn't submit or had errors
    submitted_player_ids = Map.keys(submissions)
    all_player_ids = Enum.map(all_players, &(&1.id))
    missing_players = all_player_ids -- submitted_player_ids
    Enum.each(missing_players, fn player_id ->
      ensure_zero_entries_for_player(game_id, player_id, game_state)
    end)

    # 3. Fetch the updated entries with scores to store in verified_answers_by_round
    final_round_entries = RoundEntry.get_entries_for_round(game_id, round_number)
    verified_answers_map = build_verified_answers_map(final_round_entries)

    # 4. Update GameState: store verified answers, clear submissions, update status
    updated_verified_by_round = Map.put(game_state.verified_answers_by_round || %{}, 
                                      "#{round_number}", 
                                      verified_answers_map)

    Logger.info("Storing verified answers for round #{round_number}: #{inspect(verified_answers_map)}")

    changeset(game_state, %{
      status: "verified", # Or maybe "round_complete"?
      current_round_submissions: %{}, # Clear submissions
      verified_answers_by_round: updated_verified_by_round
    })
    |> Repo.update()
    # Return the result tuple {:ok, state} or {:error, changeset}
  end

  defp build_verified_answers_map(round_entries) do
    round_entries
    |> Enum.group_by(&(&1.player_id))
    |> Enum.map(fn {player_id, entries} ->
      player_name = entries |> List.first() |> Map.get(:player) |> Map.get(:name, "Player #{player_id}")
      answers_with_scores = Enum.into(entries, %{}, fn entry ->
        {entry.category, %{answer: entry.answer, score: entry.score, reason: entry.reason || ""}}
      end)
      {player_id, %{
        name: player_name,
        answers: answers_with_scores
      }}
    end)
    |> Enum.into(%{})
  end

  defp ensure_zero_entries_for_player(game_id, player_id, state) do
    Logger.info("Ensuring zero-score entries for player #{player_id}, round #{state.current_round}")
    # Check if entries already exist for this player/round
    existing_entries = RoundEntry.get_player_entries_for_round(player_id, game_id, state.current_round)

    if Enum.empty?(existing_entries) do
      zero_answers = Enum.into(state.current_categories, %{}, fn category -> {category, ""} end)
      RoundEntry.create_entries_for_round(
        player_id,
        game_id,
        state.current_round,
        state.current_letter,
        zero_answers, # Ensure score calculation handles empty answers as 0
        0 # Explicitly set score to 0 if create_entries allows it
      )
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
        next_categories = Categories.select_next_categories(state.current_categories)

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
        # Return result tuple
    end
  end

  defp generate_random_letter do
    <<Enum.random(?A..?Z)>>
  end
end
