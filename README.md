# Constellation

A real-time multiplayer word game built with Phoenix LiveView and Elixir. Players compete to come up with words that start with a given letter across different categories. The game uses AI verification with Google's Gemini API to validate answers and calculate scores.

## Game Features

- Real-time multiplayer gameplay using Phoenix LiveView and PubSub
- Dynamic categories that change each round
- AI verification of answers using Google's Gemini API
- Detailed global leaderboard tracking player performance across all games
- Comprehensive game rules page with scoring explanations
- Beautiful space-themed UI with animated star background

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
   - 0 points for invalid answers
   - +2 bonus points for the player who stopped the round (if all their answers are valid)
   - -2 penalty points for the player who stopped the round (if none of their answers are valid)
7. After multiple rounds, the player with the most points wins!

## Leaderboard System

The game features a comprehensive leaderboard system:

- **Global Leaderboard**: Tracks player performance across all games
  - Players with the same name are combined to show their aggregate performance
  - Shows total score, games played, and average score per game
  - Accessible via the navigation menu from any page

- **Game-Specific Leaderboards**: Track detailed player performance within a single game
  - Shows round-by-round score progression
  - Highlights score changes between rounds
  - Displays bonus/penalty points from stopping rounds

## Game Rules

A detailed rules page explains the game mechanics, scoring system, and strategies:

- Basic gameplay explanation
- Comprehensive scoring rules including unique/non-unique answers
- Stopper bonus/penalty system
- Answer validation criteria
- Tips for success

The rules page is accessible from the navigation menu on any page.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
