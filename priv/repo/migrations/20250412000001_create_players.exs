defmodule Constellation.Repo.Migrations.CreatePlayers do
  use Ecto.Migration

  def change do
    create table(:players) do
      add :name, :string, null: false
      add :session_id, :string, null: false
      add :game_id, references(:games, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:players, [:game_id])
    create unique_index(:players, [:session_id, :game_id])
  end
end
