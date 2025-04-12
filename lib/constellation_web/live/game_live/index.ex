defmodule ConstellationWeb.GameLive.Index do
  use ConstellationWeb, :live_view

  alias Constellation.Games

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Constellation.PubSub, "games")
    
    {:ok, assign(socket, games: Games.list_games())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Games")
    |> assign(:game, nil)
  end

  @impl true
  def handle_info({:game_updated, _game}, socket) do
    {:noreply, assign(socket, games: Games.list_games())}
  end
  
  # Helper function for status class
  def status_class(status) do
    case status do
      :waiting -> "px-2 py-1 text-xs font-medium rounded-full bg-yellow-100 text-yellow-800"
      :in_progress -> "px-2 py-1 text-xs font-medium rounded-full bg-green-100 text-green-800"
      :completed -> "px-2 py-1 text-xs font-medium rounded-full bg-gray-100 text-gray-800"
      _ -> "px-2 py-1 text-xs font-medium rounded-full bg-gray-100 text-gray-800"
    end
  end
end
