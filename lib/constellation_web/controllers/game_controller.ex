defmodule ConstellationWeb.GameController do
  use ConstellationWeb, :controller
  alias Constellation.Games.Game
  alias Constellation.Games.Player
  
  def create(conn, %{"player_name" => player_name}) do
    # Generate a unique game name
    game_name = "Game-" <> generate_random_string(6)
    
    # Generate a session ID for the owner
    session_id = generate_random_string(16)
    
    # Create the game
    {:ok, game} = Game.create_game(%{
      name: game_name,
      owner_id: session_id
    })
    
    # Create the player (owner)
    {:ok, player} = Player.create_player(%{
      name: player_name,
      session_id: session_id,
      game_id: game.id
    })
    
    # Broadcast player joined event via PubSub
    Phoenix.PubSub.broadcast(
      Constellation.PubSub,
      "game:#{game.id}",
      {:player_joined, player}
    )
    
    # Store the session ID in the session
    conn = put_session(conn, :player_session_id, session_id)
    
    # Redirect to the game lobby
    conn
    |> put_flash(:info, "Game created successfully! Share your game code: #{game.game_code}")
    |> redirect(to: ~p"/games/#{game.id}")
  end
  
  def join(conn, %{"game_code" => game_code, "player_name" => player_name}) do
    # Check if game exists and is in waiting status
    case Game.get_game_by_code(game_code) do
      %{status: :waiting} = game ->
        # Check if the game has reached the maximum number of players
        if Game.can_join_game?(game.id) do
          # Generate a session ID for the player
          session_id = generate_random_string(16)
          
          # Create the player
          {:ok, player} = Player.create_player(%{
            name: player_name,
            session_id: session_id,
            game_id: game.id
          })
          
          # Broadcast player joined event via PubSub
          Phoenix.PubSub.broadcast(
            Constellation.PubSub,
            "game:#{game.id}",
            {:player_joined, player}
          )
          
          # Store the session ID in the session
          conn = put_session(conn, :player_session_id, session_id)
          
          # Redirect to the game lobby
          conn
          |> put_flash(:info, "Successfully joined the game!")
          |> redirect(to: ~p"/games/#{game.id}")
        else
          conn
          |> put_flash(:error, "This game has reached the maximum number of players.")
          |> redirect(to: ~p"/")
        end
        
      %{status: :in_progress} ->
        conn
        |> put_flash(:error, "This game is already in progress.")
        |> redirect(to: ~p"/")
        
      %{status: :completed} ->
        conn
        |> put_flash(:error, "This game has already been completed.")
        |> redirect(to: ~p"/")
        
      nil ->
        conn
        |> put_flash(:error, "Game not found.")
        |> redirect(to: ~p"/")
    end
  end
  
  def start(conn, %{"id" => game_id}) do
    # Get the current session ID
    current_session_id = get_session(conn, :player_session_id)
    
    # Get the game
    game = Game.get_game!(game_id)
    
    # Check if the current user is the owner of the game
    if game.owner_id == current_session_id do
      # Update game status to in_progress
      {:ok, _updated_game} = Game.update_game_status(game, :in_progress)
      
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
      
      # Redirect to the play page
      conn
      |> put_flash(:info, "Game started!")
      |> redirect(to: ~p"/games/#{game_id}/play")
    else
      conn
      |> put_status(:unauthorized)
      |> put_flash(:error, "Only the game owner can start the game.")
      |> redirect(to: ~p"/games/#{game_id}")
    end
  end
  
  def play(conn, %{"id" => id}) do
    # Get the current session ID
    current_session_id = get_session(conn, :player_session_id)
    
    # Get the game
    game = Game.get_game!(id)
    
    # Get all players in the game
    players = Player.list_players_for_game(id)
    
    # Check if the current user is a player in this game
    player = Enum.find(players, fn p -> p.session_id == current_session_id end)
    
    if player do
      # Render the game play page
      render(conn, :play, game: game, players: players, current_player: player, current_session_id: current_session_id)
    else
      # Redirect to home if not a player
      conn
      |> put_flash(:error, "You are not a player in this game.")
      |> redirect(to: ~p"/")
    end
  end
  
  def show(conn, %{"id" => id}) do
    # Get the current session ID
    current_session_id = get_session(conn, :player_session_id)
    
    # Get the game
    game = Game.get_game!(id)
    
    # Get all players in the game
    players = Player.list_players_for_game(id)
    
    # Get the current player
    current_player = Enum.find(players, fn p -> p.session_id == current_session_id end)
    
    if current_player do
      # Render the game lobby
      render(conn, :show, game: game, players: players, current_player: current_player, current_session_id: current_session_id)
    else
      # Redirect to home if not a player
      conn
      |> put_flash(:error, "You are not a player in this game.")
      |> redirect(to: ~p"/")
    end
  end
  
  defp generate_random_string(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64
    |> binary_part(0, length)
  end
end
