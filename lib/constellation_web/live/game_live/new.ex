defmodule ConstellationWeb.GameLive.New do
  use ConstellationWeb, :live_view

  alias Constellation.Games
  alias Constellation.Games.Game

  @impl true
  def mount(_params, session, socket) do
    # Generate a unique owner_id if not present in session
    owner_id = Map.get(session, "owner_id", Ecto.UUID.generate())

    {:ok,
     socket
     |> assign(:page_title, "New Game")
     |> assign(:owner_id, owner_id)
     |> assign(:changeset, Game.changeset(%Game{}, %{}))}
  end

  @impl true
  def handle_event("save", %{"game" => game_params}, socket) do
    # Add owner_id to game params
    game_params = Map.put(game_params, "owner_id", socket.assigns.owner_id)

    case Games.create_game(game_params) do
      {:ok, game} ->
        # Create the owner as first player
        player_params = %{
          "name" => "Owner",
          "session_id" => socket.assigns.owner_id,
          "game_id" => game.id
        }

        {:ok, _player} = Games.create_player(player_params)

        {:noreply,
         socket
         |> put_flash(:info, "Game created successfully")
         |> push_navigate(to: ~p"/games/#{game}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  @impl true
  def handle_event("validate", %{"game" => game_params}, socket) do
    changeset =
      %Game{}
      |> Game.changeset(game_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end
end
