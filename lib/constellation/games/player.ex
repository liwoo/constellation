defmodule Constellation.Games.Player do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  schema "players" do
    field :name, :string
    field :session_id, :string
    belongs_to :game, Constellation.Games.Game

    timestamps()
  end

  @doc false
  def changeset(player, attrs) do
    player
    |> cast(attrs, [:name, :session_id, :game_id])
    |> validate_required([:name, :session_id, :game_id])
  end

  def create_player(attrs) do
    %Constellation.Games.Player{}
    |> changeset(attrs)
    |> Constellation.Repo.insert()
  end

  def get_player!(id), do: Constellation.Repo.get!(Constellation.Games.Player, id)

  def get_player_by_session(session_id, game_id) do
    Constellation.Repo.one(
      from p in Constellation.Games.Player,
      where: p.session_id == ^session_id and p.game_id == ^game_id
    )
  end

  @doc """
  Gets a player by session ID.
  """
  def get_player_by_session_id(session_id) do
    Constellation.Repo.get_by(__MODULE__, session_id: session_id)
  end

  def list_players_for_game(game_id) do
    Constellation.Repo.all(
      from p in Constellation.Games.Player,
      where: p.game_id == ^game_id
    )
  end

  @doc """
  Count the number of players in a game
  """
  def count_players_in_game(game_id) do
    from(p in __MODULE__,
      where: p.game_id == ^game_id,
      select: count(p.id)
    )
    |> Constellation.Repo.one() || 0
  end

  @doc """
  List all players
  """
  def list_players do
    Constellation.Repo.all(__MODULE__)
  end
end
