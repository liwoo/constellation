defmodule Constellation.Repo.Migrations.AddBonusFieldsToGameStates do
  use Ecto.Migration

  def change do
    alter table(:game_states) do
      add :bonus_points, :map, default: %{}
      add :total_scores, :map, default: %{}
    end
  end
end
