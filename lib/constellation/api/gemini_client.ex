defmodule Constellation.API.GeminiClient do
  @moduledoc """
  Tesla-based client for interacting with the Google Gemini API.
  """
  use Tesla

  alias Tesla.Middleware

  @doc """
  Creates a new client with the provided API key.
  """
  def new(api_key) do
    middleware = [
      {Middleware.BaseUrl, "https://generativelanguage.googleapis.com/v1beta"},
      Middleware.JSON,
      {Tesla.Middleware.Query, [key: api_key]},
      {Middleware.Headers, [{"content-type", "application/json"}]},
      Middleware.Logger
    ]

    Tesla.client(middleware)
  end

  @doc """
  Generates content using the Gemini API.
  """
  def generate_content(prompt, api_key \\ nil) do
    api_key = api_key || System.get_env("GEMINI_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      client = new(api_key)
      
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

      case post(client, "/models/gemini-2.0-flash:generateContent", request_body) do
        {:ok, %{status: 200, body: body}} ->
          # Extract the generated text from the response
          case get_in(body, ["candidates", Access.at(0), "content", "parts", Access.at(0), "text"]) do
            nil ->
              {:error, :invalid_response_format}
            
            text ->
              {:ok, text}
          end
          
        {:ok, %{status: status, body: body}} ->
          {:error, {status, body}}
          
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Verifies a game round using the Gemini API.
  
  ## Parameters
    - letter: The round's starting letter
    - categories: List of categories used in the round
    - player_answers: List of player answer maps
    - stopper_id: Session ID of the player who stopped the round
  
  ## Returns
    - {:ok, results} on success
    - {:error, reason} on failure
  """
  def verify_round(letter, categories, player_answers, stopper_id, api_key \\ nil) do
    # Build the prompt for Gemini
    prompt = """
    You are an AI judge for a word game called "Constellation". In this game, players provide answers for different categories that start with a specific letter.

    Here are the rules:
    1. All answers must start with the letter "#{letter}".
    2. Answers are scored as follows:
       - Unique valid answer: 2 points (an answer is unique if NO OTHER player used the same answer for the same category)
       - Non-unique valid answer: 1 point (if multiple players give the same valid answer for a category)
       - Invalid answer: 0 points (including blank answers shown as "<blank>")
       - Bonus for stopping the round: 2 points (ONLY if the player who stopped the round has at least 1 point for EVERY category)

    Please verify and score the following answers:

    Categories: #{Enum.join(categories, ", ")}
    Letter: #{letter}

    Player Answers:
    #{format_player_answers_for_prompt(player_answers, categories)}

    The player with ID "#{stopper_id}" stopped the round.

    IMPORTANT: When determining if an answer is unique, compare it with ALL other players' answers for the same category. An answer is only unique if no other player provided the same answer for that category.

    IMPORTANT: The stopper bonus (2 points) should ONLY be awarded to the player who stopped the round IF they have at least 1 point for EVERY category. If any of their answers scored 0 points, they do not get the bonus.

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
    
    Return ONLY the JSON with no additional text or markdown formatting.
    """

    case generate_content(prompt, api_key) do
      {:ok, json_text} ->
        # Clean the response text by removing any markdown code block delimiters
        clean_json = json_text
          |> String.replace(~r/```json\s*/, "")
          |> String.replace(~r/```\s*$/, "")
          |> String.trim()

        # Parse the JSON from the cleaned text
        case Jason.decode(clean_json) do
          {:ok, verification_results} ->
            {:ok, verification_results}
          
          {:error, reason} ->
            require Logger
            Logger.error("Failed to parse verification results: #{inspect(reason)}")
            Logger.error("Raw text received: #{inspect(json_text)}")
            Logger.error("Cleaned text: #{inspect(clean_json)}")
            {:error, :invalid_json}
        end
        
      {:error, reason} ->
        {:error, reason}
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
end
