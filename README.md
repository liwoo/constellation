# Constellation

A real-time multiplayer word game built with Phoenix LiveView and Elixir. Players compete to come up with words that start with a given letter across different categories. The game uses AI verification with Google's Gemini API to validate answers and calculate scores.

## Game Features

- Real-time multiplayer gameplay using Phoenix LiveView and PubSub
- Dynamic categories that change each round
- AI verification of answers using Google's Gemini API
- Interactive leaderboard
- Beautiful space-themed UI

## Setup

### Environment Variables

The game uses environment variables for configuration. Follow these steps:

1. Copy the example environment file:
   ```
   cp .env.example .env
   ```

2. Edit the `.env` file and add your Gemini API key:
   ```
   GEMINI_API_KEY=your_actual_api_key_here
   ```

3. The application will automatically load these variables during startup in development.

### Starting the Server

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## How to Play

1. Create a new game or join an existing one with a game code
2. Wait for the host to start the game
3. Each round, you'll be given a letter and several categories
4. Fill in words that start with the given letter for each category
5. The first player to fill all categories and press STOP ends the round
6. The AI will verify all answers and award points:
   - 2 points for unique valid answers
   - 1 point for non-unique valid answers
   - 2 bonus points for the player who stopped the round (if all their answers are valid)
7. After 26 rounds (one for each letter), the player with the most points wins!

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
