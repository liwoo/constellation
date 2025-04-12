defmodule Constellation.Games.AIVerifier do
  @moduledoc """
  Handles verification of game rounds using Gemini AI.
  """
  require Logger

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
    
    # Call Gemini API
    case call_gemini_api(payload) do
      {:ok, response} -> parse_gemini_response(response)
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
      # Prepare the Gemini API request
      url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=#{api_key}"
      Logger.info("Calling Gemini API with payload for letter: #{payload["letter"]}")
      
      # Build the prompt for Gemini
      prompt = """
      You are an AI judge for a word game called "Constellation". In this game, players provide answers for different categories that start with a specific letter.

      Here are the rules:
      1. All answers must start with the letter "#{payload["letter"]}".
      2. Answers are scored as follows:
         - Unique valid answer: #{payload["scoring_rules"]["unique_valid"]} points
         - Non-unique valid answer: #{payload["scoring_rules"]["non_unique_valid"]} point
         - Invalid answer: #{payload["scoring_rules"]["invalid"]} points
         - Bonus for stopping the round with all valid answers: #{payload["scoring_rules"]["stopper_bonus_if_all_valid"]} points

      Please verify and score the following answers:

      Categories: #{Enum.join(payload["categories"], ", ")}
      Letter: #{payload["letter"]}

      Player Answers:
      #{format_player_answers_for_prompt(payload["player_answers"], payload["categories"])}

      The player with ID "#{payload["stopper_player_id"]}" stopped the round.

      Please provide your verification results in the following JSON format:
      [
        {
          "player_id": "player_session_id",
          "name": "player_name",
          "category_results": [
            {
              "category": "category_name",
              "answer": "player_answer",
              "is_valid": true/false,
              "is_unique": true/false,
              "points": score_value
            },
            ...
          ],
          "base_points": total_base_points,
          "is_stopper": true/false,
          "stopper_bonus": bonus_points,
          "total_points": total_points_with_bonus
        },
        ...
      ]
      
      Return ONLY the JSON with no additional text.
      """
      
      # Prepare the request body
      request_body = %{
        "contents" => [
          %{
            "parts" => [
              %{
                "text" => prompt
              }
            ]
          }
        ]
      }
      
      # Make the HTTP request
      Logger.debug("Sending request to Gemini API")
      case HTTPoison.post(url, Jason.encode!(request_body), [{"Content-Type", "application/json"}]) do
        {:ok, response} when is_map(response) and response.status_code == 200 ->
          # Parse the response
          Logger.info("Received 200 OK response from Gemini API")
          case Jason.decode(response.body) do
            {:ok, response_data} ->
              # Extract the generated text from the response
              Logger.debug("Successfully decoded response JSON")
              case get_in(response_data, ["candidates", Access.at(0), "content", "parts", Access.at(0), "text"]) do
                nil ->
                  Logger.error("Failed to extract text from Gemini API response: #{inspect(response_data)}")
                  {:error, :invalid_response_format}
                
                text ->
                  # Parse the JSON from the text
                  Logger.debug("Extracted text from Gemini response, parsing as JSON")
                  case Jason.decode(text) do
                    {:ok, verification_results} ->
                      Logger.info("Successfully parsed verification results: #{length(verification_results)} player results")
                      {:ok, verification_results}
                    
                    {:error, reason} ->
                      Logger.error("Failed to parse verification results: #{inspect(reason)}")
                      Logger.error("Raw text received: #{inspect(text)}")
                      mock_gemini_verification(payload)
                  end
              end
            
            {:error, reason} ->
              Logger.error("Failed to parse Gemini API response: #{inspect(reason)}")
              mock_gemini_verification(payload)
          end
        
        {:ok, response} when is_map(response) ->
          Logger.error("Gemini API returned status code #{response.status_code}: #{response.body}")
          mock_gemini_verification(payload)
        
        {:error, reason} ->
          Logger.error("Failed to call Gemini API: #{inspect(reason)}")
          mock_gemini_verification(payload)
      end
    end
  end
  
  # Format player answers for the Gemini prompt
  defp format_player_answers_for_prompt(player_answers, categories) do
    player_answers
    |> Enum.map(fn player ->
      """
      Player: #{player["name"]} (ID: #{player["session_id"]})
      #{format_player_categories(player["answers"], categories)}
      """
    end)
    |> Enum.join("\n")
  end
  
  # Format a player's category answers
  defp format_player_categories(answers, categories) do
    categories
    |> Enum.map(fn category ->
      answer = Map.get(answers, category, "")
      "- #{category}: #{answer}"
    end)
    |> Enum.join("\n")
  end
  
  @doc """
  Parses the response from Gemini API.
  """
  def parse_gemini_response(response) do
    # In a real implementation, parse JSON response
    # For now, we'll just return the mock response
    {:ok, response}
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
