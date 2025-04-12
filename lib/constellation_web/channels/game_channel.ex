defmodule ConstellationWeb.GameChannel do
  use Phoenix.Channel
  alias ConstellationWeb.Presence
  alias Constellation.Games
  
  def join("game:" <> game_id, %{"player_id" => player_id, "player_name" => player_name}, socket) do
    # Get the game to check if the player is the owner
    game = Games.Game.get_game!(game_id)
    is_owner = game.owner_id == player_id
    
    # Subscribe to PubSub topic for this game
    Phoenix.PubSub.subscribe(Constellation.PubSub, "game:#{game_id}")
    
    send(self(), :after_join)
    
    socket = socket
      |> assign(:game_id, game_id)
      |> assign(:player_id, player_id)
      |> assign(:player_name, player_name)
      |> assign(:is_owner, is_owner)
      
    {:ok, socket}
  end

  def handle_info(:after_join, socket) do
    {:ok, _} = Presence.track(socket, socket.assigns.player_id, %{
      player_name: socket.assigns.player_name,
      online_at: inspect(System.system_time(:second)),
      is_owner: socket.assigns.is_owner
    })

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end
  
  # Handle PubSub broadcasts
  def handle_info({:player_joined, player}, socket) do
    # Relay the player joined event to the channel
    broadcast!(socket, "player_joined", %{
      id: player.id,
      name: player.name,
      session_id: player.session_id
    })
    
    {:noreply, socket}
  end

  # Handle game_started event from PubSub
  def handle_info({:game_started, data}, socket) do
    # Relay the game started event to all clients in the channel
    broadcast!(socket, "game_started", data)
    {:noreply, socket}
  end
  
  # Handle round_stopped event from PubSub
  def handle_info({:round_stopped, data}, socket) do
    # Relay the round stopped event to all clients in the channel
    broadcast!(socket, "round_stopped", data)
    {:noreply, socket}
  end
  
  # Handle round_update event from PubSub
  def handle_info({:round_update, data}, socket) do
    # Relay the round update event to all clients in the channel
    broadcast!(socket, "round_update", data)
    {:noreply, socket}
  end
  
  # Handle leaderboard_update event from PubSub
  def handle_info({:leaderboard_update, data}, socket) do
    # Relay the leaderboard update event to all clients in the channel
    broadcast!(socket, "leaderboard_update", data)
    {:noreply, socket}
  end
end
