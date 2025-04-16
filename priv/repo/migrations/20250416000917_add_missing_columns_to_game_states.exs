defmodule Constellation.Repo.Migrations.AddMissingColumnsToGameStates do
  use Ecto.Migration

  def change do
    alter table(:game_states) do
      # Add the columns explicitly
      add_if_not_exists :verified_answers_by_round, :map, default: %{}
      add_if_not_exists :current_round_submissions, :map, default: %{}
      
      # If the player_answers column still exists, drop it
      remove_if_exists :player_answers, :map
    end
  end
end
