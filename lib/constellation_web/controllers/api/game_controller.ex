defmodule ConstellationWeb.API.GameController do
  use ConstellationWeb, :controller
  alias Constellation.Games.Game
  alias Constellation.Games.Player
  alias Constellation.Games.RoundEntry
  alias Constellation.Games.GameState
  
  def players(conn, %{"id" => game_id}) do
    # Get all players in the game
    players = Player.list_players_for_game(game_id)
    
    # Return JSON response with players and count
    json(conn, %{
      player_count: length(players),
      players: Enum.map(players, fn player -> 
        %{
          id: player.id,
          name: player.name,
          session_id: player.session_id
        }
      end)
    })
  end
  
  def status(conn, %{"id" => game_id}) do
    # Get the game
    _game = Game.get_game!(game_id)
    
    # Get all players in the game with scores
    players = Player.list_players_for_game(game_id)
    players_with_scores = Enum.map(players, fn player -> 
      %{
        id: player.id,
        name: player.name,
        session_id: player.session_id,
        score: RoundEntry.calculate_player_score(player.id, game_id) || 0
      }
    end)
    
    # Get complete game state
    game_state = GameState.get_game_state(game_id)
    
    # Get player who stopped the round (if any)
    stopper_id = GameState.get_round_stopper(game_id)
    stopper = if stopper_id, do: Enum.find(players_with_scores, &(&1.session_id == stopper_id))
    
    # Get current round answers if in verification state
    player_answers = if game_state && game_state.status == "verifying" do
      GameState.get_current_round_answers(game_id)
    else
      []
    end
    
    # Return JSON response with game status
    json(conn, %{
      status: if(game_state, do: game_state.status, else: "in_progress"),
      current_round: if(game_state, do: game_state.current_round, else: 1),
      current_letter: if(game_state, do: game_state.current_letter, else: "A"),
      round_stopped: if(game_state, do: game_state.round_stopped, else: false),
      current_categories: if(game_state, do: game_state.current_categories, else: []),
      players: players_with_scores,
      stopper_name: if(stopper, do: stopper.name, else: nil),
      player_answers: player_answers
    })
  end
end
