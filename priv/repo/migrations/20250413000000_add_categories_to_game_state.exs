defmodule Constellation.Repo.Migrations.AddCategoriesToGameState do
  use Ecto.Migration

  def change do
    alter table(:game_states) do
      add :current_categories, {:array, :string}, default: []
      add :status, :string, default: "in_progress"
      add :player_answers, :map, default: %{}
      add :stopper_id, :string, null: true
    end
  end
end
