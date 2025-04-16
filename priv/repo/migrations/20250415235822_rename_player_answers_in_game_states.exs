defmodule Constellation.Repo.Migrations.RenamePlayerAnswersInGameStates do
  use Ecto.Migration

  def change do
    alter table(:game_states) do
      # Rename using modify/3
      modify :player_answers, :map, rename: :verified_answers_by_round

      # Add the new column for temporary submissions
      add :current_round_submissions, :map, default: %{}
    end
  end
end
