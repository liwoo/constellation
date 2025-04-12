defmodule Constellation.Games do
  @moduledoc """
  The Games context.
  """

  alias Constellation.Games.Game
  alias Constellation.Games.Player
  alias Phoenix.PubSub

  @pubsub Constellation.PubSub

  # Game functions
  def list_games, do: Game.list_games()
  def list_waiting_games, do: Game.list_waiting_games()
  def get_game!(id), do: Game.get_game!(id)

  def create_game(attrs) do
    with {:ok, game} <- Game.create_game(attrs) do
      broadcast_game_change(game)
      {:ok, game}
    end
  end

  def start_game(game_id) do
    with game = %Game{} <- get_game!(game_id),
         true <- Game.can_start_game?(game_id),
         {:ok, updated_game} <- Game.update_game_status(game, :in_progress) do
      broadcast_game_change(updated_game)
      {:ok, updated_game}
    else
      false -> {:error, :not_enough_players}
      error -> error
    end
  end

  # Player functions
  def create_player(attrs) do
    with {:ok, player} <- Player.create_player(attrs) do
      broadcast_player_joined(player)
      {:ok, player}
    end
  end

  def list_players_for_game(game_id), do: Player.list_players_for_game(game_id)
  def count_players_in_game(game_id), do: Player.count_players_in_game(game_id)

  def get_player_by_session(session_id, game_id) do
    Player.get_player_by_session(session_id, game_id)
  end

  # PubSub functions
  def subscribe_to_game(game_id) do
    PubSub.subscribe(@pubsub, "game:#{game_id}")
  end

  def broadcast_game_change(game) do
    PubSub.broadcast(@pubsub, "game:#{game.id}", {:game_updated, game})
  end

  def broadcast_player_joined(player) do
    PubSub.broadcast(@pubsub, "game:#{player.game_id}", {:player_joined, player})
  end

  # Game state functions
  def can_start_game?(game_id) do
    Game.can_start_game?(game_id)
  end
end
