defmodule ConstellationWeb.GameLive.Show do
  use ConstellationWeb, :live_view

  alias Constellation.Games

  @impl true
  def mount(%{"id" => id}, session, socket) do
    # Generate a session_id if not present
    session_id = Map.get(session, "session_id", Ecto.UUID.generate())
    
    if connected?(socket) do
      Games.subscribe_to_game(id)
    end

    game = Games.get_game!(id)
    players = Games.list_players_for_game(id)
    
    # Check if the current user is already a player
    current_player = Games.get_player_by_session(session_id, id)
    is_owner = game.owner_id == session_id
    can_start = Games.can_start_game?(id) and is_owner

    socket =
      socket
      |> assign(:game, game)
      |> assign(:players, players)
      |> assign(:session_id, session_id)
      |> assign(:current_player, current_player)
      |> assign(:is_owner, is_owner)
      |> assign(:can_start, can_start)
      |> assign(:player_name, "")

    {:ok, socket}
  end

  @impl true
  def handle_event("join_game", %{"player" => %{"name" => name}}, socket) do
    game_id = socket.assigns.game.id
    session_id = socket.assigns.session_id

    # Create a new player
    player_params = %{
      "name" => name,
      "session_id" => session_id,
      "game_id" => game_id
    }

    case Games.create_player(player_params) do
      {:ok, player} ->
        {:noreply,
         socket
         |> assign(:current_player, player)
         |> put_flash(:info, "Joined game successfully")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Error joining game")}
    end
  end

  @impl true
  def handle_event("start_game", _params, socket) do
    game_id = socket.assigns.game.id

    case Games.start_game(game_id) do
      {:ok, _game} ->
        {:noreply, put_flash(socket, :info, "Game started!")}

      {:error, :not_enough_players} ->
        {:noreply, put_flash(socket, :error, "Not enough players to start the game")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Error starting game")}
    end
  end

  @impl true
  def handle_info({:game_updated, game}, socket) do
    is_owner = game.owner_id == socket.assigns.session_id
    can_start = Games.can_start_game?(game.id) and is_owner

    {:noreply,
     socket
     |> assign(:game, game)
     |> assign(:can_start, can_start)}
  end

  @impl true
  def handle_info({:player_joined, _player}, socket) do
    game_id = socket.assigns.game.id
    players = Games.list_players_for_game(game_id)
    is_owner = socket.assigns.game.owner_id == socket.assigns.session_id
    can_start = Games.can_start_game?(game_id) and is_owner

    {:noreply,
     socket
     |> assign(:players, players)
     |> assign(:can_start, can_start)}
  end
end
