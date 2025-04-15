defmodule ConstellationWeb.LeaderboardController do
  use ConstellationWeb, :controller
  require Logger
  
  alias Constellation.Games.Game
  alias Constellation.Games.Player
  alias Constellation.Games.RoundEntry
  alias Constellation.Games.GameState

  @doc """
  Renders the global leaderboard page showing top players across all games
  """
  def index(conn, _params) do
    # Get top players by total score across all games
    top_players = get_top_players()
    render(conn, :index, top_players: top_players)
  end

  @doc """
  Renders the leaderboard for a specific game
  """
  def show(conn, %{"game_id" => game_id}) do
    # Get the game
    case Game.get_game(game_id) do
      nil ->
        conn
        |> put_flash(:error, "Game not found")
        |> redirect(to: ~p"/leaderboard")
        
      game ->
        # Get player scores with round-by-round breakdown
        player_scores = get_player_scores_by_round(game_id)
        render(conn, :show, game: game, player_scores: player_scores)
    end
  end

  # Private functions
  
  # Get top players across all games
  defp get_top_players do
    # Get all players
    players = Player.list_players()
    
    # Calculate total score for each player across all games
    players_with_scores = Enum.map(players, fn player ->
      total_score = RoundEntry.calculate_player_total_score(player.id)
      games_played = RoundEntry.count_games_played(player.id)
      %{
        id: player.id,
        name: player.name,
        total_score: total_score,
        games_played: games_played,
        avg_score: if(games_played > 0, do: total_score / games_played * 1.0, else: 0.0)
      }
    end)
    
    # Group players by name
    players_by_name = Enum.group_by(players_with_scores, fn player -> player.name end)
    
    # Combine stats for players with the same name
    combined_players = Enum.map(players_by_name, fn {name, players_list} ->
      # Sum up total scores and games played
      total_score = Enum.reduce(players_list, 0, fn player, acc -> acc + player.total_score end)
      games_played = Enum.reduce(players_list, 0, fn player, acc -> acc + player.games_played end)
      
      # Get all player IDs
      player_ids = Enum.map(players_list, fn player -> player.id end)
      
      # Calculate average score
      avg_score = if(games_played > 0, do: total_score / games_played * 1.0, else: 0.0)
      
      %{
        id: player_ids,  # Store all IDs as a list
        name: name,
        total_score: total_score,
        games_played: games_played,
        avg_score: avg_score
      }
    end)
    
    # Sort by total score and return top 20
    combined_players
    |> Enum.sort_by(fn p -> p.total_score end, :desc)
    |> Enum.take(20)
  end
  
  # Get detailed player scores by round for a specific game
  defp get_player_scores_by_round(game_id) do
    # Get all players in the game
    players = Player.list_players_for_game(game_id)
    
    # Get the current game state to know how many rounds
    game_state = GameState.get_game_state(game_id)
    max_round = if game_state, do: game_state.current_round, else: 1
    
    # For each player, get their scores for each round
    player_data = Enum.map(players, fn player ->
      # Get all entries for this player in this game
      entries = RoundEntry.get_entries_for_player(player.id, game_id)
      
      # Group entries by round
      entries_by_round = Enum.group_by(entries, & &1.round_number)
      
      # Calculate score for each round
      round_scores = Enum.map(1..max_round, fn round ->
        round_entries = Map.get(entries_by_round, round, [])
        
        # Calculate regular score for this round
        regular_entries = Enum.filter(round_entries, fn entry -> entry.category != "STOPPER_BONUS" end)
        regular_score = Enum.reduce(regular_entries, 0, fn entry, acc -> acc + (entry.score || 0) end)
        
        # Get bonus entry if it exists
        bonus_entry = Enum.find(round_entries, fn entry -> entry.category == "STOPPER_BONUS" end)
        bonus_score = if bonus_entry, do: bonus_entry.score || 0, else: 0
        
        # Calculate total score for this round
        round_score = regular_score + bonus_score
        
        %{
          round: round,
          regular_score: regular_score,
          bonus_score: bonus_score,
          total_score: round_score
        }
      end)
      
      # Calculate cumulative scores and deltas between rounds
      {cumulative_scores, _} = Enum.map_reduce(round_scores, 0, fn round_data, prev_total ->
        new_total = prev_total + round_data.total_score
        delta = round_data.total_score
        
        updated_round_data = Map.merge(round_data, %{
          cumulative_score: new_total,
          delta: delta
        })
        
        {updated_round_data, new_total}
      end)
      
      # Calculate total score
      total_score = Enum.reduce(round_scores, 0, fn round_data, acc -> 
        acc + round_data.total_score
      end)
      
      %{
        player_id: player.id,
        name: player.name,
        total_score: total_score,
        round_scores: cumulative_scores
      }
    end)
    
    # Group players by name
    players_by_name = Enum.group_by(player_data, fn player -> player.name end)
    
    # Combine stats for players with the same name
    combined_players = Enum.map(players_by_name, fn {name, players_list} ->
      # If there's only one player with this name, just return that player's data
      if length(players_list) == 1 do
        hd(players_list)
      else
        # Combine multiple players with the same name
        
        # Get all player IDs
        player_ids = Enum.map(players_list, fn player -> player.player_id end)
        
        # Sum up total scores
        total_score = Enum.reduce(players_list, 0, fn player, acc -> 
          acc + player.total_score
        end)
        
        # Combine round scores - for each round, sum the scores of all players
        # First, get the maximum number of rounds across all players
        max_rounds = Enum.max_by(players_list, fn player -> 
          length(player.round_scores)
        end).round_scores |> length()
        
        # Initialize combined round scores
        combined_round_scores = Enum.map(1..max_rounds, fn round_index ->
          # Find all round data for this round index across all players
          round_data_list = Enum.flat_map(players_list, fn player ->
            # Find the round data for this round index
            Enum.filter(player.round_scores, fn round_data ->
              round_data.round == round_index
            end)
          end)
          
          # Sum up scores for this round
          total_round_score = Enum.reduce(round_data_list, 0, fn round_data, acc ->
            acc + round_data.total_score
          end)
          
          regular_score = Enum.reduce(round_data_list, 0, fn round_data, acc ->
            acc + round_data.regular_score
          end)
          
          bonus_score = Enum.reduce(round_data_list, 0, fn round_data, acc ->
            acc + round_data.bonus_score
          end)
          
          # Calculate delta (will be the same as total_round_score for combined players)
          delta = total_round_score
          
          # Calculate cumulative score
          # This is tricky because we need to sum up all previous rounds too
          previous_rounds = Enum.filter(1..round_index, fn r -> r < round_index end)
          previous_total = Enum.reduce(previous_rounds, 0, fn prev_round, acc ->
            prev_round_data_list = Enum.flat_map(players_list, fn player ->
              Enum.filter(player.round_scores, fn rd -> rd.round == prev_round end)
            end)
            
            prev_round_total = Enum.reduce(prev_round_data_list, 0, fn rd, inner_acc ->
              inner_acc + rd.total_score
            end)
            
            acc + prev_round_total
          end)
          
          cumulative_score = previous_total + total_round_score
          
          %{
            round: round_index,
            regular_score: regular_score,
            bonus_score: bonus_score,
            total_score: total_round_score,
            delta: delta,
            cumulative_score: cumulative_score
          }
        end)
        
        %{
          player_id: player_ids,
          name: name,
          total_score: total_score,
          round_scores: combined_round_scores
        }
      end
    end)
    
    # Sort by total score and return
    combined_players
    |> Enum.sort_by(fn p -> p.total_score end, :desc)
  end
end
