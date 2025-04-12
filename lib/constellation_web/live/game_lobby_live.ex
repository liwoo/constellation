defmodule ConstellationWeb.GameLobbyLive do
  use ConstellationWeb, :live_view
  
  alias Constellation.Games.Game
  alias Constellation.Games.Player
  
  def mount(%{"id" => game_id}, session, socket) do
    # Get current session ID
    current_session_id = session["player_session_id"]
    
    # Get the game
    game = Game.get_game!(game_id)
    
    # Get all players in the game
    players = Player.list_players_for_game(game_id)
    
    # Get the current player
    current_player = Enum.find(players, fn p -> p.session_id == current_session_id end)
    
    if connected?(socket) do
      # Subscribe to game updates
      Phoenix.PubSub.subscribe(Constellation.PubSub, "game:#{game_id}")
    end
    
    socket = socket
      |> assign(:game, game)
      |> assign(:game_id, game_id)
      |> assign(:current_session_id, current_session_id)
      |> assign(:current_player, current_player)
      |> assign(:players, players)
      |> assign(:is_owner, game.owner_id == current_session_id)
    
    {:ok, socket}
  end
  
  # Handle start game button click
  def handle_event("start_game", _params, socket) do
    game_id = socket.assigns.game_id
    
    # Update game status to in_progress
    {:ok, _updated_game} = Game.update_game_status(socket.assigns.game, :in_progress)
    
    # Initialize game state with first round and letter
    {:ok, game_state} = Constellation.Games.GameState.initialize_game_state(game_id)
    
    # Broadcast game start event to all players
    Phoenix.PubSub.broadcast(
      Constellation.PubSub,
      "game:#{game_id}",
      {:game_started, %{
        round: game_state.current_round,
        letter: game_state.current_letter,
        categories: game_state.current_categories
      }}
    )
    
    # Redirect owner to the play page
    {:noreply, push_navigate(socket, to: ~p"/games/#{game_id}/play")}
  end
  
  # Handle PubSub broadcasts
  def handle_info({:player_joined, player}, socket) do
    # Refresh player list
    players = Player.list_players_for_game(socket.assigns.game_id)
    
    socket = socket
      |> assign(:players, players)
      |> put_flash(:info, "#{player.name} joined the game!")
    
    {:noreply, socket}
  end
  
  def handle_info({:game_started, _data}, socket) do
    # Redirect to the play page when game starts
    {:noreply, push_navigate(socket, to: ~p"/games/#{socket.assigns.game_id}/play")}
  end
end
