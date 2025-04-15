defmodule Constellation.Games.Game do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  schema "games" do
    field :name, :string
    field :status, Ecto.Enum, values: [:waiting, :in_progress, :completed], default: :waiting
    field :owner_id, :string
    field :game_code, :string
    field :min_players, :integer, default: 2
    field :max_players, :integer, default: 6
    
    has_many :players, Constellation.Games.Player

    timestamps()
  end

  @doc false
  def changeset(game, attrs) do
    game
    |> cast(attrs, [:name, :status, :owner_id, :min_players, :max_players, :game_code])
    |> validate_required([:name, :owner_id])
    |> validate_number(:min_players, greater_than_or_equal_to: 2)
    |> validate_number(:max_players, greater_than_or_equal_to: :min_players)
    |> maybe_generate_game_code()
  end

  defp maybe_generate_game_code(changeset) do
    if get_field(changeset, :game_code) do
      changeset
    else
      put_change(changeset, :game_code, generate_game_code())
    end
  end

  defp generate_game_code do
    allowed_chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    code_length = 6
    
    1..code_length
    |> Enum.map(fn _ -> String.at(allowed_chars, :rand.uniform(String.length(allowed_chars)) - 1) end)
    |> Enum.join("")
  end

  @doc """
  Get a game by ID (returns nil if not found)
  """
  def get_game(id) do
    Constellation.Repo.get(__MODULE__, id)
  end

  def get_game!(id), do: Constellation.Repo.get!(Constellation.Games.Game, id)

  def get_game_by_code(code) do
    Constellation.Repo.one(from g in Constellation.Games.Game, where: g.game_code == ^code)
  end

  def create_game(attrs) do
    %Constellation.Games.Game{}
    |> changeset(attrs)
    |> Constellation.Repo.insert()
  end

  def update_game_status(game, status) do
    game
    |> change(%{status: status})
    |> Constellation.Repo.update()
  end

  def list_games do
    Constellation.Repo.all(Constellation.Games.Game)
  end

  def list_waiting_games do
    Constellation.Repo.all(from g in Constellation.Games.Game, where: g.status == :waiting)
  end

  def list_recent_games(limit \\ 10) do
    from(g in __MODULE__,
      order_by: [desc: g.inserted_at],
      limit: ^limit
    )
    |> Constellation.Repo.all()
  end

  def can_start_game?(game_id) do
    query = from g in Constellation.Games.Game,
            join: p in assoc(g, :players),
            where: g.id == ^game_id,
            group_by: g.id,
            having: count(p.id) >= g.min_players,
            select: count(p.id)
    
    case Constellation.Repo.one(query) do
      nil -> false
      count when is_integer(count) -> true
    end
  end

  def can_join_game?(game_id) do
    query = from g in Constellation.Games.Game,
            join: p in assoc(g, :players),
            where: g.id == ^game_id,
            group_by: [g.id, g.max_players],
            select: %{count: count(p.id), max: g.max_players}
    
    case Constellation.Repo.one(query) do
      nil -> true  # No players yet
      %{count: count, max: max} -> count < max
    end
  end
end
