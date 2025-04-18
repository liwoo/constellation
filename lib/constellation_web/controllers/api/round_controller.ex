defmodule ConstellationWeb.API.RoundController do
  use ConstellationWeb, :controller
  alias Constellation.Games.Game
  alias Constellation.Games.Player
  alias Constellation.Games.RoundEntry
  alias Constellation.Games.GameState
  # alias Constellation.Games.AIVerifier
  
  @doc """
  Handle round submissions from players
  """
  def create(conn, %{"id" => game_id} = params) do
    # Get the current session ID
    current_session_id = get_session(conn, :player_session_id)
    
    # Get the player
    player = Player.get_player_by_session_id(current_session_id)
    
    if player && player.game_id == game_id do
      # Extract round data
      round_number = params["round"]
      letter = params["letter"]
      answers = params["answers"]
      stopped = params["stopped"] || false
      
      # Record player answers in the game state
      GameState.record_player_submission(game_id, player.id, answers)
      
      # Save round data to database
      case RoundEntry.create_entries_for_round(player.id, game_id, round_number, letter, answers) do
        {:ok, _} ->
          # If this player pressed STOP, mark the round as stopped
          if stopped do
            # Mark the round as stopped in the game state
            GameState.mark_round_as_stopped(game_id, current_session_id)
            
            # Broadcast to all players that the round has been stopped
            Phoenix.PubSub.broadcast(
              Constellation.PubSub,
              "game:#{game_id}",
              {:round_stopped, %{round: round_number, stopped_by: player.name}}
            )
            
            # Start AI verification process (this could be moved to a background job)
            # For now, we'll do it synchronously for simplicity
            Task.start(fn -> 
              # Add a small delay to allow all players to submit their answers
              Process.sleep(2000)
              GameState.verify_round(game_id)
            end)
          end
          
          # Check if all players have submitted their answers for this round
          all_submitted = all_players_submitted?(game_id, round_number)
          
          if all_submitted do
            # Calculate scores for this round
            RoundEntry.score_round(game_id, round_number)
            
            # Get updated scores for all players
            players_with_scores = get_players_with_scores(game_id)
            
            # If not the last round, start the next round
            if round_number < 26 do
              # Advance to the next round
              {:ok, new_state} = GameState.advance_to_next_round(game_id)
              
              # Broadcast round update
              Phoenix.PubSub.broadcast(
                Constellation.PubSub,
                "game:#{game_id}",
                {:round_update, %{round: new_state.current_round, letter: new_state.current_letter}}
              )
            else
              # Game completed
              game = Game.get_game!(game_id)
              Game.update_game_status(game, :completed)
              
              # Broadcast game completed
              Phoenix.PubSub.broadcast(
                Constellation.PubSub,
                "game:#{game_id}",
                {:game_completed, %{winners: get_winners(game_id)}}
              )
            end
            
            # Broadcast leaderboard update
            Phoenix.PubSub.broadcast(
              Constellation.PubSub,
              "game:#{game_id}",
              {:leaderboard_update, %{players: players_with_scores}}
            )
          end
          
          json(conn, %{success: true, message: "Round submitted successfully"})
          
        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{success: false, message: "Failed to save round data: #{reason}"})
      end
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{success: false, message: "You are not authorized to submit for this game"})
    end
  end
  
  @doc """
  Get the current game status, including round, letter, categories, and player answers
  """
  def status(conn, %{"id" => game_id}) do
    # Get the current session ID
    current_session_id = get_session(conn, :player_session_id)
    
    # Get the player
    player = Player.get_player_by_session_id(current_session_id)
    
    if player && player.game_id == game_id do
      # Get game state
      game_state = GameState.get_game_state(game_id)
      
      # Get all players with their scores
      players_with_scores = get_players_with_scores(game_id)
      
      # Get player who stopped the round (if any)
      stopper_id = GameState.get_round_stopper(game_id)
      stopper = if stopper_id, do: Enum.find(players_with_scores, &(&1.session_id == stopper_id))
      
      # Get current round answers if in verification state
      player_answers = if game_state.status == "verifying" do
        GameState.get_current_round_answers(game_id)
      else
        []
      end
      
      # Return game status
      json(conn, %{
        status: game_state.status,
        current_round: game_state.current_round,
        current_letter: game_state.current_letter,
        round_stopped: game_state.round_stopped,
        current_categories: game_state.current_categories,
        players: players_with_scores,
        stopper_name: if(stopper, do: stopper.name, else: nil),
        player_answers: player_answers
      })
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{success: false, message: "You are not authorized to view this game"})
    end
  end
  
  # Check if all players have submitted their answers for this round
  defp all_players_submitted?(game_id, round_number) do
    # Get all players in the game
    players = Player.list_players_for_game(game_id)
    player_count = length(players)
    
    # Get all entries for this round
    entries = RoundEntry.get_entries_for_round(game_id, round_number)
    
    # Group entries by player
    entries_by_player = Enum.group_by(entries, & &1.player_id)
    
    # Count players who have submitted entries
    submitted_player_count = map_size(entries_by_player)
    
    # All players have submitted if the counts match
    submitted_player_count == player_count
  end
  
  # Get players with their scores
  defp get_players_with_scores(game_id) do
    # Get all players in the game
    players = Player.list_players_for_game(game_id)
    
    # Calculate scores for each player
    Enum.map(players, fn player ->
      score = RoundEntry.calculate_player_score(player.id, game_id)
      
      %{
        id: player.id,
        name: player.name,
        session_id: player.session_id,
        score: score
      }
    end)
  end
  
  # Get the winners of the game (players with highest scores)
  defp get_winners(game_id) do
    # Get all players with their scores
    players_with_scores = get_players_with_scores(game_id)
    
    # Find the highest score
    highest_score = players_with_scores
    |> Enum.map(& &1.score)
    |> Enum.max(fn -> 0 end)
    
    # Get all players with the highest score
    players_with_scores
    |> Enum.filter(& &1.score == highest_score)
    |> Enum.map(fn player -> 
      %{
        id: player.id,
        name: player.name,
        score: player.score
      }
    end)
  end
end
