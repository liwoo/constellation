defmodule Constellation.Games.RoundEntry do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Constellation.Repo
  alias Constellation.Games.Player
  alias Constellation.Games.Game

  schema "round_entries" do
    field :answer, :string
    field :category, :string
    field :letter, :string
    field :round_number, :integer
    field :score, :integer, default: 0
    field :verification_status, :string, default: "pending"
    field :is_valid, :boolean, default: nil
    field :ai_explanation, :string
    belongs_to :player, Player
    belongs_to :game, Game

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(round_entry, attrs) do
    round_entry
    |> cast(attrs, [:round_number, :letter, :category, :answer, :score, :player_id, :game_id, :verification_status, :is_valid, :ai_explanation])
    |> validate_required([:round_number, :letter, :category, :answer, :player_id, :game_id])
  end
  
  @doc """
  Create a new round entry for a player
  """
  def create_entry(attrs \\ %{}) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end
  
  @doc """
  Create multiple entries for a player in a single round
  """
  def create_entries_for_round(player_id, game_id, round_number, letter, answers) do
    # Convert the answers map to a list of entries
    entries = Enum.map(answers, fn {category, answer} ->
      %{
        player_id: player_id,
        game_id: game_id,
        round_number: round_number,
        letter: letter,
        category: to_string(category),
        answer: answer,
        score: 0 # Initial score, will be updated after scoring
      }
    end)
    
    # Insert all entries in a transaction
    Repo.transaction(fn ->
      Enum.each(entries, fn entry ->
        create_entry(entry)
      end)
    end)
  end
  
  @doc """
  Get all entries for a specific round in a game
  """
  def get_entries_for_round(game_id, round_number) do
    from(e in __MODULE__,
      where: e.game_id == ^game_id and e.round_number == ^round_number,
      preload: [:player]
    )
    |> Repo.all()
  end
  
  @doc """
  Get all entries for a player in a game
  """
  def get_entries_for_player(player_id, game_id) do
    from(e in __MODULE__,
      where: e.player_id == ^player_id and e.game_id == ^game_id,
      order_by: [asc: e.round_number]
    )
    |> Repo.all()
  end
  
  @doc """
  Calculate the total score for a player in a game
  """
  def calculate_player_score(player_id, game_id) do
    from(e in __MODULE__,
      where: e.player_id == ^player_id and e.game_id == ^game_id,
      select: sum(e.score)
    )
    |> Repo.one() || 0
  end
  
  @doc """
  Get all entries for a specific player in a specific round
  """
  def get_entries_for_player_round(game_id, player_id, round_number) do
    from(e in __MODULE__,
      where: e.game_id == ^game_id and e.player_id == ^player_id and e.round_number == ^round_number
    )
    |> Repo.all()
  end
  
  @doc """
  Score entries for a round based on uniqueness
  
  Scoring rules:
  - 10 points for a unique answer
  - 5 points for an answer given by some but not all players
  - 0 points for an answer given by all players or invalid answers
  """
  def score_round(game_id, round_number) do
    # Get all entries for this round
    entries = get_entries_for_round(game_id, round_number)
    
    # Group entries by category
    entries_by_category = Enum.group_by(entries, & &1.category)
    
    # For each category, score the entries
    Repo.transaction(fn ->
      Enum.each(entries_by_category, fn {_category, category_entries} ->
        # Count occurrences of each answer
        answer_counts = Enum.reduce(category_entries, %{}, fn entry, acc ->
          normalized_answer = String.downcase(entry.answer)
          Map.update(acc, normalized_answer, 1, &(&1 + 1))
        end)
        
        # Total number of players
        player_count = length(Enum.uniq(Enum.map(category_entries, & &1.player_id)))
        
        # Score each entry
        Enum.each(category_entries, fn entry ->
          normalized_answer = String.downcase(entry.answer)
          count = Map.get(answer_counts, normalized_answer, 0)
          
          # Assign score based on uniqueness
          score = cond do
            # Invalid answer (doesn't start with the round letter)
            not String.starts_with?(normalized_answer, String.downcase(entry.letter)) -> 0
            # Unique answer
            count == 1 -> 10
            # Answer given by all players
            count == player_count -> 0
            # Answer given by some players
            true -> 5
          end
          
          # Update the entry with the score
          entry
          |> changeset(%{score: score})
          |> Repo.update!()
        end)
      end)
    end)
    
    :ok
  end
  
  @doc """
  Get the current round number for a game
  """
  def get_current_round(game_id) do
    # Get the highest round number for this game
    max_round = from(e in __MODULE__,
      where: e.game_id == ^game_id,
      select: max(e.round_number)
    )
    |> Repo.one()
    
    # If no rounds yet, return 1, otherwise return the next round
    case max_round do
      nil -> 1
      round -> round + 1
    end
  end
  
  @doc """
  Get the current letter for a game's current round
  """
  def get_current_letter(game_id) do
    # Get the current round
    current_round = get_current_round(game_id)
    
    # Get an entry from this round to find the letter
    entry = from(e in __MODULE__,
      where: e.game_id == ^game_id and e.round_number == ^current_round,
      limit: 1
    )
    |> Repo.one()
    
    # If no entry found, use a default letter (S)
    case entry do
      nil -> "S"
      entry -> entry.letter
    end
  end
end
