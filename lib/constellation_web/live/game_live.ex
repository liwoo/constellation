defmodule ConstellationWeb.GameLive do
  use ConstellationWeb, :live_view
  
  alias Constellation.Games.Game
  alias Constellation.Games.Player
  alias Constellation.Games.GameState
  alias Constellation.Games.RoundEntry
  require Logger
  
  @impl true
  def mount(%{"id" => game_id}, session, socket) do
    # Get current session ID
    current_session_id = session["player_session_id"]
    
    # Get the game
    game = Constellation.Games.Game.get_game!(game_id)
    
    # Get all players in the game
    players = Constellation.Games.Player.list_players_for_game(game_id)
    
    # Get the current player
    current_player = Enum.find(players, fn p -> p.session_id == current_session_id end)
    
    if connected?(socket) do
      # Subscribe to game updates
      Phoenix.PubSub.subscribe(Constellation.PubSub, "game:#{game_id}")
    end
    
    # Get current game state
    game_state = Constellation.Games.GameState.get_game_state(game_id) || %Constellation.Games.GameState{game_id: game_id}
    
    # Get players with scores
    players_with_scores = get_players_with_scores(game_id)
    
    socket = socket
      |> assign(:game, game)
      |> assign(:game_id, game_id)
      |> assign(:current_session_id, current_session_id)
      |> assign(:current_player, current_player)
      |> assign(:players, players_with_scores)
      |> assign(:current_round, game_state.current_round || 1)
      |> assign(:current_letter, game_state.current_letter || "?")
      |> assign(:current_categories, game_state.current_categories || [])
      |> assign(:round_stopped, game_state.round_stopped || false)
      |> assign(:game_status, game_state.status || "in_progress")
      |> assign(:verification_data, nil)
      |> assign(:form, to_form(%{}))
      |> assign(:owner_id, game.owner_id)
      |> assign(:stopper_name, nil)
      |> assign(:is_verifying, game_state.status == "verifying")
      |> assign(:show_verification_modal, game_state.status == "verifying")
      |> assign_new(:show_sidebar, fn -> false end)
      |> assign_new(:show_scores_modal, fn -> false end)
      |> assign_new(:player_scores, fn -> [] end)
      |> assign(:is_owner, current_session_id == game.owner_id)
      |> assign(:all_fields_filled, false) # Initialize all_fields_filled to false
      |> assign(:form_values, %{}) # Initialize form_values to an empty map
      |> assign(:verification_status, nil)
      |> assign(:show_countdown_modal, false) # Initialize countdown modal state
      |> assign(:countdown_seconds, 5) # Initialize countdown seconds
    
    # If the game is in progress and we just connected, start the countdown
    if connected?(socket) && game_state.status == "in_progress" do
      Process.send_after(self(), :start_countdown, 500)
    end
    
    {:ok, socket}
  end
  
  # Handle events
  @impl true
  def handle_event("stop_round", _params, socket) do
    game_id = socket.assigns.game_id
    current_player = socket.assigns.current_player
    
    # Only proceed if the round isn't already stopped or verifying
    if socket.assigns.round_stopped || socket.assigns.is_verifying do
      {:noreply, socket}
    else
      Logger.info("Player #{current_player.name} (#{current_player.id}) stopping round #{socket.assigns.current_round}")
      
      # Get the current game state
      game_state = Constellation.Games.GameState.get_game_state!(game_id)
      
      # Update the game state to mark the round as stopped and set status to collecting
      updated_state = Constellation.Games.GameState.update_game_state(game_state, %{
        round_stopped: true,
        stopper_id: to_string(current_player.id),
        status: "collecting"
      })
      
      # Broadcast to all players that the round is stopping and they should submit their answers
      Phoenix.PubSub.broadcast(
        Constellation.PubSub,
        "game:#{game_id}",
        {:round_stopping, %{stopper_name: current_player.name, round_number: updated_state.current_round, submit_answers: true}}
      )
      
      # Also broadcast a game state update
      Phoenix.PubSub.broadcast(
        Constellation.PubSub,
        "game:#{game_id}",
        {:game_state_updated, %{
          status: "collecting",
          round_number: updated_state.current_round,
          round_stopped: true,
          stopper_name: current_player.name,
          message: "#{current_player.name} stopped the round! Collecting answers..."
        }}
      )
      
      # Submit this player's answers immediately
      submit_current_player_answers(socket)
      
      # Update the socket with the new state and show verification modal immediately
      socket = socket
        |> assign(:round_stopped, true)
        |> assign(:stopper_name, current_player.name)
        |> assign(:verification_status, "starting")
        |> assign(:show_verification_modal, true)
      
      # If this player is the owner or designated coordinator, schedule aggregation
      if socket.assigns.is_owner do
        Logger.info("This player (#{current_player.name}) is the owner, scheduling aggregation in 5 seconds")
        # Schedule aggregation after a delay to allow all players to submit
        Process.send_after(
          self(), 
          {:initiate_aggregation, game_id, updated_state.current_round},
          5000  # 5 second delay
        )
      else
        Logger.info("This player (#{current_player.name}) is not the owner, not scheduling aggregation")
      end
      
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("stop_game", _value, socket) do
    game_id = socket.assigns.game_id
    current_session_id = socket.assigns.current_session_id
    
    # Safely get player name
    player_name = case socket.assigns do
      %{current_player: %{name: name}} when is_binary(name) -> name
      _ -> "Unknown Player"
    end
    
    # Check if the player has filled in all categories for this round
    player_entries = Constellation.Games.RoundEntry.get_entries_for_player_round(
      game_id,
      current_session_id,
      socket.assigns.current_round
    )
    
    # Get the list of categories for this round
    categories = socket.assigns.current_categories
    
    # Check if all categories have entries
    all_categories_filled = Enum.all?(categories, fn category ->
      Enum.any?(player_entries, fn entry -> entry.category == category && entry.answer && entry.answer != "" end)
    end)
    
    if all_categories_filled do
      # Broadcast stop message to all players via PubSub
      Phoenix.PubSub.broadcast(
        Constellation.PubSub, 
        "game:" <> game_id, 
        {:stop_requested, %{player_name: player_name, session_id: current_session_id}}
      )
  
      # Show verification modal immediately for everyone
      {:noreply, 
        socket
        |> assign(:stopper_name, player_name)
        |> assign(:round_stopped, true)
        |> assign(:show_verification_modal, true)
      }
    else
      # Notify the player that they need to fill in all categories
      {:noreply,
        socket
        |> put_flash(:error, "You must fill in all categories before stopping the round.")
      }
    end
  end
  
  @impl true
  def handle_event("next_round", _value, socket) do
    game_id = socket.assigns.game_id

    if socket.assigns.is_owner do
      Logger.info("Owner triggering next round for game #{game_id}")
      
      # Reset game state for the next round and broadcast to all players
      case Constellation.Games.GameState.advance_to_next_round(game_id) do
        {:ok, _new_state} ->
          {:noreply, 
            socket
            |> assign(:show_scores_modal, false)
            |> assign(:player_scores, [])
            |> assign(:verification_data, nil)
            |> assign(:form_values, %{})  # Reset form values for new round
            |> assign(:form, to_form(%{}))  # Reset the form itself
            |> assign(:all_fields_filled, false)  # Reset validation state
          }
        {:error, reason} ->
          Logger.error("Failed to advance round: #{inspect(reason)}")
          {:noreply, socket}
      end
    else
      # Ignore if not owner
      Logger.warning("Non-owner attempted to start next round")
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_sidebar", _value, socket) do
    {:noreply, update(socket, :show_sidebar, &(!&1))}
  end

  @impl true
  def handle_event("validate_input", params, socket) do
    # Get the current categories
    categories = socket.assigns.current_categories
    
    # Log the received params for debugging
    Logger.info("Validate input params: #{inspect(params)}")
    
    # Get current form values
    current_values = socket.assigns.form_values || %{}
    
    # Update form values with new input - drop internal Phoenix fields
    updated_values = 
      params
      |> Map.drop(["_target", "_csrf_token"])
      |> Enum.reduce(current_values, fn {k, v}, acc -> 
          Map.put(acc, k, v) 
        end)
    
    Logger.info("Updated form values: #{inspect(updated_values)}")
    
    # Check if all categories have non-empty values
    all_filled = Enum.all?(categories, fn category ->
      value = Map.get(updated_values, category, "")
      result = String.trim(value) != ""
      Logger.info("Category #{category}: value='#{value}', filled=#{result}")
      result
    end)
    
    # Log validation result
    Logger.info("All fields filled: #{all_filled}, categories: #{inspect(categories)}")
    
    # Update the all_fields_filled assign and store current values
    {:noreply, 
      socket
      |> assign(:all_fields_filled, all_filled)
      |> assign(:form_values, updated_values)
    }
  end
  
  # Handle info
  @impl true
  def handle_info({:game_started, data}, socket) do
    socket = socket
      |> assign(:current_round, data.round)
      |> assign(:current_letter, data.letter)
      |> assign(:current_categories, data.categories)
      |> assign(:round_stopped, false)
      |> assign(:game_status, "in_progress")
      |> assign(:verification_data, nil)
      |> assign(:is_verifying, false)
      |> assign(:stopper_name, nil)
      |> assign(:form_values, %{})  # Reset form values for new round
      |> assign(:all_fields_filled, false)  # Reset validation state
      |> assign(:form, to_form(%{}))  # Reset the form itself
      |> assign(:show_scores_modal, false)  # Dismiss the scores modal for all players
    
    # Start countdown for the new round
    Process.send_after(self(), :start_countdown, 100)
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_info({:stop_requested, data}, socket) do
    unless socket.assigns.stopper_name do
      Logger.info("Received stop request from #{data.player_name}")
      socket = socket
        |> assign(:round_stopped, true)
        |> assign(:is_verifying, true)
        |> assign(:stopper_name, data.player_name)
        |> assign(:game_status, "verifying")
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end
  
  @impl true
  def handle_info({:round_update, data}, socket) do
     Logger.info("Received round update: #{inspect(data)}")
     socket = socket
       |> assign(:current_round, data.round)
       |> assign(:current_letter, data.letter)
       |> assign(:current_categories, data.categories)
       |> assign(:round_stopped, data.status != "in_progress")
       |> assign(:game_status, data.status) 
       |> assign(:verification_data, Map.get(data, :results))
       |> assign(:is_verifying, data.status == "verifying")
       |> assign(:stopper_name, if(data.status == "verifying", do: socket.assigns.stopper_name, else: nil))
       |> assign(:players, get_players_with_scores(socket.assigns.game_id))
       |> assign(:form_values, %{})  # Reset form values for new round
       |> assign(:form, to_form(%{}))  # Reset the form itself

     # If the game status is "in_progress", dismiss the scores modal and start the countdown
     socket = if data.status == "in_progress" do
       Process.send_after(self(), :start_countdown, 100)
       assign(socket, :show_scores_modal, false)  # Dismiss the scores modal
     else
       socket
     end

     # If verification just completed, hide verification modal and show scores modal
     socket = if data.status == "completed_verification" do
       Process.send_after(self(), :verification_complete, 500)
       socket
     else
       socket
     end

     {:noreply, socket}
  end

  @impl true
  def handle_info({:game_state_updated, data}, socket) do
    # Update the socket with the new game state
    Logger.info("Game state updated: #{inspect(data)}")
    Logger.info("Current socket assigns before update: is_verifying=#{socket.assigns.is_verifying}, show_verification_modal=#{socket.assigns[:show_verification_modal] || false}, game_status=#{socket.assigns.game_status}")
    
    socket = socket
      |> assign(:game_status, data.status)
      
    # Additional updates based on the status
    socket = if data.status == "verifying" do
      Logger.info("Setting is_verifying=true and show_verification_modal=true")
      socket
        |> assign(:is_verifying, true)
        |> assign(:verification_status, "in_progress")
        |> assign(:show_verification_modal, true)
    else
      socket
    end
    
    # Update stopper_name if provided
    socket = if Map.has_key?(data, :stopper_name) do
      Logger.info("Setting stopper_name=#{data.stopper_name}")
      socket |> assign(:stopper_name, data.stopper_name)
    else
      socket
    end
    
    # Update round_stopped if provided
    socket = if Map.has_key?(data, :round_stopped) do
      Logger.info("Setting round_stopped=#{data.round_stopped}")
      socket |> assign(:round_stopped, data.round_stopped)
    else
      socket
    end
    
    Logger.info("Updated socket assigns: is_verifying=#{socket.assigns.is_verifying}, show_verification_modal=#{socket.assigns[:show_verification_modal] || false}, game_status=#{socket.assigns.game_status}")
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_info({:trigger_verification, game_id, stopper_session_id}, socket) do
    current_status = Constellation.Games.GameState.get_game_status(game_id)

    if current_status != "verifying" do
      Logger.info("Triggering verification for game #{game_id} by stopper #{stopper_session_id}")
      
      {:ok, _} = Constellation.Games.GameState.mark_round_as_stopped(game_id, stopper_session_id)

      # Instead of using Task.Supervisor, we'll use Process.send_after to handle the verification
      # This keeps the verification process within the LiveView process
      Process.send_after(self(), {:perform_verification, game_id}, 100)
      
      socket = socket
        |> assign(:verification_status, "starting")
        |> assign(:show_verification_modal, true)
      
      {:noreply, socket}
    else
      Logger.info("Verification already in progress or completed for game #{game_id}, skipping trigger.")
      {:noreply, socket}
    end
  end
  
  @impl true
  def handle_info({:perform_verification, game_id}, socket) do
    Logger.info("Starting verification process for game #{game_id}")
    
    # Update socket to show verification in progress
    socket = socket
      |> assign(:verification_status, "in_progress")
    
    # Perform the verification within the LiveView process
    case Constellation.Games.GameState.verify_round(game_id) do
      {:ok, _results} ->
        Logger.info("Verification completed successfully for game #{game_id}")
        {:noreply, socket |> assign(:verification_status, "completed")}
        
      {:error, reason} ->
        Logger.error("Verification failed for game #{game_id}: #{inspect(reason)}")
        
        # Use a simple mock verification to complete the process
        Logger.info("Falling back to simple mock verification")
        
        # Get the game state
        game_state = Constellation.Games.GameState.get_game_state!(game_id)
        
        # Create a simple mock result
        mock_results = create_mock_verification_results(game_state)
        
        # Process the mock results
        case Constellation.Games.GameState.process_verification_results(game_id, mock_results) do
          {:ok, _} ->
            Logger.info("Mock verification completed successfully for game #{game_id}")
            {:noreply, socket |> assign(:verification_status, "completed")}
            
          {:error, mock_error} ->
            Logger.error("Mock verification failed for game #{game_id}: #{inspect(mock_error)}")
            {:noreply, socket |> assign(:verification_status, "failed")}
        end
    end
  end
  
  # Create simple mock verification results
  defp create_mock_verification_results(game_state) do
    # Get all players in the game
    players = Constellation.Games.Player.list_players_for_game(game_state.game_id)
    
    # Create a mock result for each player
    Enum.map(players, fn player ->
      # Get this player's submissions
      player_submissions = Map.get(game_state.current_round_submissions || %{}, to_string(player.id)) || 
                          Map.get(game_state.current_round_submissions || %{}, player.id) || 
                          %{}
      
      # Create category results
      category_results = Enum.map(game_state.current_categories, fn category ->
        answer = Map.get(player_submissions, category, "")
        is_valid = String.length(answer) > 0 && String.first(answer) == String.first(game_state.current_letter)
        
        %{
          "category" => category,
          "answer" => answer,
          "is_valid" => is_valid,
          "is_unique" => true,
          "points" => if(is_valid, do: 2, else: 0),
          "explanation" => if(is_valid, 
                            do: "Valid answer starting with #{game_state.current_letter}", 
                            else: "Invalid or missing answer")
        }
      end)
      
      # Calculate base points
      base_points = Enum.reduce(category_results, 0, fn result, acc -> acc + result["points"] end)
      
      # Determine if this player is the stopper
      is_stopper = player.session_id == game_state.stopper_id
      
      # Calculate stopper bonus
      all_valid = Enum.all?(category_results, fn result -> result["is_valid"] end)
      stopper_bonus = if(is_stopper && all_valid, do: 2, else: 0)
      
      # Create the player result
      %{
        "player_id" => player.session_id,
        "name" => player.name,
        "category_results" => category_results,
        "base_points" => base_points,
        "is_stopper" => is_stopper,
        "stopper_bonus" => stopper_bonus,
        "total_points" => base_points + stopper_bonus
      }
    end)
  end
  
  @impl true
  def handle_info({:round_stopping, data}, socket) do
    # Another player has stopped the round
    # Update local state to reflect this
    Logger.info("Round stopping notification received from #{data.stopper_name}")
    game_id = socket.assigns.game_id
    
    socket = socket
      |> assign(:round_stopped, true)
      |> assign(:stopper_name, data.stopper_name)
      |> assign(:game_status, "collecting")
      |> assign(:verification_status, "starting") # Set verification status
      |> assign(:show_verification_modal, true)   # Show verification modal immediately
    
    # If this message includes submit_answers: true, submit this player's current answers
    if Map.get(data, :submit_answers, false) do
      Logger.info("Submitting answers in response to round stop by #{data.stopper_name}")
      submit_current_player_answers(socket)
    end
    
    # If this player is the owner, schedule a direct verification after a delay
    # This serves as a backup in case the initiate_aggregation message doesn't work
    if socket.assigns.is_owner do
      Logger.info("This player is the owner, scheduling direct verification in 7 seconds")
      Process.send_after(
        self(),
        {:trigger_direct_verification, game_id},
        7000  # 7 second delay (longer than the aggregation delay)
      )
    end
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_info({:trigger_direct_verification, game_id}, socket) do
    Logger.info("Direct verification trigger for game #{game_id}")
    
    # Get the current game state
    game_state = Constellation.Games.GameState.get_game_state!(game_id)
    
    # Only proceed if we're still in collecting phase
    if game_state.status == "collecting" && game_state.round_stopped do
      Logger.info("Game is still in collecting phase and round is stopped, forcing transition to verification")
      
      # Update game state to verifying
      updated_state = Constellation.Games.GameState.update_game_state(game_state, %{
        status: "verifying"
      })
      
      # Broadcast status update to all players
      Phoenix.PubSub.broadcast(
        Constellation.PubSub,
        "game:#{game_id}",
        {:game_state_updated, %{
          status: "verifying",
          round_number: updated_state.current_round,
          message: "Verifying answers..."
        }}
      )
      
      # Trigger verification process
      Process.send_after(self(), {:perform_verification, game_id}, 1000)
      
      {:noreply, socket |> assign(:verification_status, "starting") |> assign(:show_verification_modal, true)}
    else
      Logger.info("Game is not in collecting phase or round is not stopped, skipping direct verification")
      {:noreply, socket}
    end
  end
  
  @impl true
  def handle_info({:initiate_aggregation, game_id, round_number}, socket) do
    Logger.info("Received initiate_aggregation message for game #{game_id}, round #{round_number}")
    Logger.info("Current player is_owner: #{socket.assigns.is_owner}, session_id: #{socket.assigns.current_session_id}")
    
    # This message is only processed by the owner or designated coordinator
    if socket.assigns.is_owner do
      Logger.info("Initiating aggregation for game #{game_id}, round #{round_number}")
      
      # Get the latest game state with all collected submissions
      game_state = Constellation.Games.GameState.get_game_state!(game_id)
      Logger.info("Game state: status=#{game_state.status}, current_round=#{game_state.current_round}, round_stopped=#{game_state.round_stopped}")
      
      # Only proceed if we're still in collecting phase for the correct round
      if game_state.current_round == round_number && game_state.status == "collecting" do
        # Get all player submissions from the game state
        all_submissions = game_state.current_round_submissions || %{}
        
        Logger.info("Found #{map_size(all_submissions)} submissions for round #{round_number}")
        
        # Save all submissions to RoundEntry
        Enum.each(all_submissions, fn {player_id_str, answers} ->
          # Convert player_id to integer if it's a string
          player_id = if is_binary(player_id_str), do: String.to_integer(player_id_str), else: player_id_str
          
          Logger.info("Saving entries for player #{player_id}")
          
          # Create entries for this player's answers
          Constellation.Games.RoundEntry.create_entries_for_round(
            player_id,
            game_id,
            round_number,
            game_state.current_letter,
            answers
          )
        end)
        
        # Update game state to verifying
        updated_state = Constellation.Games.GameState.update_game_state(game_state, %{
          status: "verifying"
        })
        
        # Broadcast status update to all players
        Phoenix.PubSub.broadcast(
          Constellation.PubSub,
          "game:#{game_id}",
          {:game_state_updated, %{
            status: "verifying",
            round_number: round_number,
            message: "Verifying answers..."
          }}
        )
        
        # Trigger verification process
        Process.send_after(self(), {:perform_verification, game_id}, 1000)
        
        {:noreply, socket}
      else
        Logger.info("Aggregation not initiated for game #{game_id}, round #{round_number}: not in collecting phase")
        {:noreply, socket}
      end
    else
      Logger.info("Aggregation not initiated for game #{game_id}, round #{round_number}: not owner/coordinator")
      {:noreply, socket}
    end
  end
  
  @impl true
  def handle_info(:start_countdown, socket) do
    Logger.info("Starting countdown for round #{socket.assigns.current_round}")
    
    # Only start countdown if we're not already counting down and the game is in progress
    if !socket.assigns.show_countdown_modal && socket.assigns.game_status == "in_progress" do
      socket = socket
        |> assign(:show_countdown_modal, true)
        |> assign(:countdown_seconds, 5)
      
      # Schedule the first tick
      Process.send_after(self(), :tick_countdown, 1000)
      
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end
  
  @impl true
  def handle_info(:tick_countdown, socket) do
    # Only process if we're still showing the countdown modal
    if socket.assigns.show_countdown_modal do
      # Decrement the countdown
      new_seconds = socket.assigns.countdown_seconds - 1
      
      socket = socket |> assign(:countdown_seconds, new_seconds)
      
      if new_seconds > 0 do
        # Schedule the next tick
        Process.send_after(self(), :tick_countdown, 1000)
        {:noreply, socket}
      else
        # Countdown finished, hide the modal and ensure form is reset
        socket = socket 
          |> assign(:show_countdown_modal, false)
          |> assign(:form_values, %{})  # Reset form values when countdown ends
          |> assign(:form, to_form(%{}))  # Reset the form itself
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end
  
  @impl true
  def handle_info(:verification_complete, socket) do 
    # Fetch/calculate scores and verified answers
    game_id = socket.assigns.game_id
    Logger.info("Calculating scores for game #{game_id} after verification completed")
    
    scores = calculate_player_scores(game_id) 
    Logger.info("Calculated scores: #{inspect(scores)}")

    {:noreply,
      socket
      |> assign(:show_verification_modal, false)
      |> assign(:show_scores_modal, true)
      |> assign(:player_scores, scores)}
  end
  
  # Private functions
  defp calculate_player_scores(game_id) do
    # Get verification data and calculate scores from the database
    try do
      # Get the current game state
      game_state = case Constellation.Games.GameState.get_game_state(game_id) do
        {:ok, state} -> state
        %Constellation.Games.GameState{} = state -> state
        _ -> nil
      end
      
      if game_state && game_state.status == "completed_verification" do
        # Get all verified entries for the current round from the database
        round_entries = Constellation.Games.RoundEntry.get_entries_for_round(
          game_id, 
          game_state.current_round
        )
        
        Logger.info("Found #{length(round_entries)} entries for round #{game_state.current_round}")
        # Log the first few entries for debugging
        if length(round_entries) > 0 do
          sample_entries = Enum.take(round_entries, min(3, length(round_entries)))
          Logger.debug("Sample entries: #{inspect(sample_entries, pretty: true)}")
        end
        
        # Get players for the game
        players = Constellation.Games.Player.list_players_for_game(game_id)
        Logger.info("Found #{length(players)} players for game #{game_id}")
        Logger.debug("Players: #{inspect(players, pretty: true)}")
        
        # Group entries by player
        entries_by_player = Enum.group_by(round_entries, fn entry -> entry.player_id end)
        Logger.debug("Entries by player: #{inspect(Map.keys(entries_by_player))}")
        
        # Transform entries into player scores, ensuring ALL players are included
        player_scores = players
        |> Enum.map(fn player ->
          # Get entries for this player (or empty list if none)
          entries = Map.get(entries_by_player, player.id, [])
          Logger.debug("Player #{player.name} (#{player.id}) has #{length(entries)} entries")
          
          # Separate regular entries from bonus entries
          {regular_entries, bonus_entries} = Enum.split_with(entries, fn entry -> 
            entry.category != "STOPPER_BONUS"
          end)
          
          # Calculate score from regular entries
          regular_score = Enum.reduce(regular_entries, 0, fn entry, acc -> 
            score_value = entry.score || 0
            Logger.debug("Regular entry score for #{player.name}: #{entry.category} = #{score_value}")
            acc + score_value
          end)
          
          # Calculate bonus/penalty from stopper entries
          stopper_bonus = Enum.reduce(bonus_entries, 0, fn entry, acc ->
            bonus_value = entry.score || 0
            Logger.debug("Stopper bonus for #{player.name}: #{bonus_value}")
            acc + bonus_value
          end)
          
          # Calculate total score
          total_score = regular_score + stopper_bonus
          Logger.debug("Total score for #{player.name}: regular=#{regular_score}, bonus=#{stopper_bonus}, total=#{total_score}")
          
          # Get all answers with their verification status and scores
          all_answers = entries
          |> Enum.filter(fn entry -> 
            # Filter out entries with _unused_ prefix in category and include only regular categories
            !String.starts_with?(entry.category, "_unused_") && entry.category != "STOPPER_BONUS"
          end)
          |> Enum.map(fn entry -> 
            status_text = cond do
              entry.verification_status != "completed" -> "(pending)"
              entry.is_valid -> "(valid - #{entry.score} points)"
              true -> "(invalid - 0 points)"
            end
            
            %{
              category: entry.category,
              answer: entry.answer,
              status_text: status_text,
              is_valid: entry.is_valid,
              score: entry.score || 0,
              explanation: entry.ai_explanation || "No explanation available"
            }
          end)
          
          # Check if player has a stopper bonus
          stopper_bonus_entry = Enum.find(entries, fn entry -> entry.category == "STOPPER_BONUS" end)
          
          # Create player score entry
          %{
            player_id: player.id,
            name: player.name,
            score: total_score,
            verified_answers: all_answers,
            stopper_bonus: if(stopper_bonus_entry, do: stopper_bonus_entry.score, else: 0)
          }
        end)
        |> Enum.sort_by(fn entry -> entry.score end, :desc) # Sort by score descending
        
        Logger.info("Calculated scores for #{length(player_scores)} players")
        Logger.info("Calculated scores: #{inspect(player_scores)}")
        player_scores
      else
        reason = if game_state, do: "verification not completed", else: "game state not found"
        Logger.info("Game #{game_id} scores not available: #{reason}")
        []
      end
    rescue
      e ->
        Logger.error("Error calculating scores: #{inspect(e)}")
        []
    end
  end
  
  defp get_players_with_scores(game_id) do
    players = Constellation.Games.Player.list_players_for_game(game_id)
    Enum.map(players, fn player ->
      score = Constellation.Games.RoundEntry.calculate_player_score(player.id, game_id) || 0
      %{
        id: player.id,
        name: player.name,
        session_id: player.session_id,
        score: score
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end
  
  # Submit the current player's answers to the game state
  defp submit_current_player_answers(socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.current_player.id
    form_values = socket.assigns.form_values || %{}
    current_categories = socket.assigns.current_categories
    
    Logger.info("Submitting answers for player #{player_id} in game #{game_id}: #{inspect(form_values)}")
    
    # Ensure all categories have a value (even if blank)
    complete_form_values = Enum.reduce(current_categories, form_values, fn category, acc ->
      if Map.has_key?(acc, category) do
        acc
      else
        Map.put(acc, category, "")
      end
    end)
    
    # Record the submission in the game state
    case Constellation.Games.GameState.record_player_submission(game_id, player_id, complete_form_values) do
      {:ok, _updated_state} ->
        Logger.info("Successfully recorded submission for player #{player_id}")
      {:error, reason} ->
        Logger.error("Failed to record submission for player #{player_id}: #{inspect(reason)}")
    end
  end
end
