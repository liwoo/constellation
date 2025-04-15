defmodule Constellation.Games.AIVerifier do
  @moduledoc """
  Handles verification of game rounds using Gemini AI.
  """
  require Logger
  alias Constellation.API.GeminiClient

  @doc """
  Verifies a round's answers using Gemini AI.
  
  ## Parameters
    - letter: The round's starting letter
    - categories: List of categories used in the round
    - player_answers: List of player answer maps
    - stopper_id: Session ID of the player who stopped the round
  
  ## Returns
    - {:ok, results} on success
    - {:error, reason} on failure
  """
  def verify_round(letter, categories, player_answers, stopper_id) do
    # Prepare payload for Gemini
    payload = build_verification_payload(letter, categories, player_answers, stopper_id)
    
    # Call Gemini API using the new client
    case call_gemini_api(payload) do
      {:ok, response} -> {:ok, response}
      {:error, _} = error -> error
    end
  end
  
  @doc """
  Builds the payload to send to Gemini API.
  """
  def build_verification_payload(letter, categories, player_answers, stopper_id) do
    %{
      "letter" => letter,
      "categories" => categories,
      "player_answers" => player_answers,
      "scoring_rules" => %{
        "unique_valid" => 2,
        "non_unique_valid" => 1,
        "invalid" => 0,
        "stopper_bonus_if_all_valid" => 2
      },
      "stopper_player_id" => stopper_id
    }
  end
  
  @doc """
  Calls the Gemini API with the verification payload.
  """
  def call_gemini_api(payload) do
    # Get API key from environment
    api_key = System.get_env("GEMINI_API_KEY")
    
    if is_nil(api_key) or api_key == "" do
      Logger.warning("GEMINI_API_KEY not set, using mock verification")
      mock_gemini_verification(payload)
    else
      Logger.info("Calling Gemini API with payload for letter: #{payload["letter"]}")
      
      # Use the new GeminiClient to verify the round
      case GeminiClient.verify_round(
        payload["letter"],
        payload["categories"],
        payload["player_answers"],
        payload["stopper_player_id"],
        api_key
      ) do
        {:ok, verification_results} ->
          Logger.info("Successfully received verification results: #{length(verification_results)} player results")
          {:ok, verification_results}
          
        {:error, :invalid_json} ->
          Logger.error("Failed to parse JSON from Gemini API response")
          mock_gemini_verification(payload)
          
        {:error, {status, body}} ->
          Logger.error("Gemini API returned error status #{status}: #{inspect(body)}")
          mock_gemini_verification(payload)
          
        {:error, reason} ->
          Logger.error("Failed to call Gemini API: #{inspect(reason)}")
          mock_gemini_verification(payload)
      end
    end
  end
  
  @doc """
  Mock implementation of Gemini verification for development.
  """
  def mock_gemini_verification(payload) do
    # Extract data from payload
    letter = payload["letter"]
    categories = payload["categories"]
    player_answers = payload["player_answers"]
    stopper_id = payload["stopper_player_id"]
    
    # Process each player's answers
    results = Enum.map(player_answers, fn player ->
      # Calculate points for each category
      category_results = Enum.map(categories, fn category ->
        answer = player["answers"][category]
        
        # Check if answer is valid (starts with correct letter and not empty)
        is_valid = answer && String.trim(answer) != "" && 
                  String.downcase(String.first(answer)) == String.downcase(letter)
        
        # Check if answer is unique among all players
        is_unique = is_valid && 
                    Enum.count(player_answers, fn p -> 
                      p["answers"][category] && 
                      String.downcase(p["answers"][category]) == String.downcase(answer)
                    end) == 1
        
        # Calculate points
        points = cond do
          is_unique -> 2  # Unique valid answer
          is_valid -> 1   # Valid but not unique
          true -> 0       # Invalid or empty
        end
        
        %{
          "category" => category,
          "answer" => answer,
          "is_valid" => is_valid,
          "is_unique" => is_unique,
          "points" => points
        }
      end)
      
      # Calculate total points
      base_points = Enum.reduce(category_results, 0, fn result, acc -> 
        acc + result["points"]
      end)
      
      # Check if player gets stopper bonus
      is_stopper = player["session_id"] == stopper_id
      all_answers_valid = Enum.all?(category_results, fn result -> result["is_valid"] end)
      stopper_bonus = if is_stopper && all_answers_valid, do: 2, else: 0
      
      total_points = base_points + stopper_bonus
      
      %{
        "player_id" => player["session_id"],
        "name" => player["name"],
        "category_results" => category_results,
        "base_points" => base_points,
        "is_stopper" => is_stopper,
        "stopper_bonus" => stopper_bonus,
        "total_points" => total_points
      }
    end)
    
    # Return mock response
    {:ok, results}
  end
end
