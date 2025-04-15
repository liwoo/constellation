defmodule Constellation.Repo.Migrations.AddMissingBonusFieldsToGameStates do
  use Ecto.Migration

  def up do
    # Check if columns already exist before adding them
    execute "SELECT column_name FROM information_schema.columns WHERE table_name='game_states' AND column_name='bonus_points'"
    |> case do
      {:ok, %{num_rows: 0}} ->
        alter table(:game_states) do
          add :bonus_points, :map, default: %{}
        end
      _ -> :ok
    end

    execute "SELECT column_name FROM information_schema.columns WHERE table_name='game_states' AND column_name='total_scores'"
    |> case do
      {:ok, %{num_rows: 0}} ->
        alter table(:game_states) do
          add :total_scores, :map, default: %{}
        end
      _ -> :ok
    end
  end

  def down do
    # We don't want to drop these columns in down migration
    # as they might be used by other migrations
    :ok
  end
end
