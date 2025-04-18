defmodule Constellation.Analytics do
  @moduledoc """
  Helper module for sending analytics events to Mixpanel.
  """
  require Logger

  # Correct the application name according to your mix.exs config
  @mixpanel_token Application.compile_env(:mixpanel, :token)

  @doc """
  Tracks an event in Mixpanel.

  Uses the configured Mixpanel token. Logs an error if the token is not set.
  Sends events asynchronously using Task.start/1.

  ## Parameters
    - `event_name`: The name of the event (e.g., "Game Started").
    - `distinct_id`: A unique identifier for the user performing the action (e.g., player_id).
    - `properties`: A map of additional data associated with the event.

  ## Returns
    - `:ok` if the event was queued for sending
    - `{:error, :no_token}` if Mixpanel isn't configured
  """
  def track(event_name, distinct_id, properties \\ %{}) do
    if @mixpanel_token do
      # Send asynchronously to avoid blocking game logic
      Task.start(fn ->
        try do
          # TODO: Verify this matches the MixPanel library's function signature
          MixPanel.track(@mixpanel_token, event_name, distinct_id, properties)
        rescue
          e ->
            Logger.error("Error sending event to Mixpanel: #{inspect(e)}")
        end
      end)
      :ok
    else
      # Log locally if Mixpanel isn't configured, but don't crash
      Logger.warning("Mixpanel token not configured. Event '#{event_name}' not sent.")
      Logger.debug("Mixpanel Event Data: #{inspect(%{event: event_name, distinct_id: distinct_id, properties: properties})}")
      {:error, :no_token}
    end
  end

  # Example convenience functions (add more as needed)

  def track_game_started(game_id, player_id) do
    track("Game Started", player_id, %{game_id: game_id})
  end

  def track_player_joined(game_id, player_id, player_count) do
    track("Player Joined", player_id, %{game_id: game_id, player_count: player_count})
  end

  def track_round_started(game_id, player_id, round_number, letter) do
    # Use game_id as distinct_id if event is not tied to a specific player action
    track("Round Started", game_id, %{game_id: game_id, player_id: player_id, round_number: round_number, letter: letter})
  end

  def track_submission_received(game_id, player_id, round_number, category_count) do
    track("Submission Received", player_id, %{game_id: game_id, round_number: round_number, category_count: category_count})
  end

  @doc """
  Tracks the completion of a verification round.
  """
  def track_verification_complete(game_id, round_number, player_scores) do
    # Ensure player_scores is serializable
    serializable_scores = sanitize_for_json(player_scores)
    # Use game_id as distinct_id for simplicity, adjust if needed
    track("Verification Complete", game_id, %{
      game_id: game_id,
      round_number: round_number,
      scores: serializable_scores
    })
  end

  @doc """
  Tracks the end of a game.
  """
  def track_game_ended(game_id, final_scores) do
    # Ensure final_scores is serializable
    serializable_scores = sanitize_for_json(final_scores)
    # Use game_id as distinct_id for simplicity, adjust if needed
    track("Game Ended", game_id, %{
      game_id: game_id,
      final_scores: serializable_scores
    })
  end

  # --- Helper Functions ---

  # Helper function to ensure data is JSON-serializable by converting atoms.
  defp sanitize_for_json(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} -> {sanitize_for_json(k), sanitize_for_json(v)} end)
    |> Map.new()
  end
  defp sanitize_for_json(data) when is_list(data) do
    Enum.map(data, &sanitize_for_json/1)
  end
  defp sanitize_for_json(data) when is_atom(data) and not is_boolean(data) and not is_nil(data) do
    Atom.to_string(data)
  end
  defp sanitize_for_json(data), do: data # Handles strings, numbers, booleans, nil
end
