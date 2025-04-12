defmodule Constellation.Repo.Migrations.AddGameCodeToGames do
  use Ecto.Migration

  def change do
    alter table(:games) do
      add :game_code, :string
    end
    
    create unique_index(:games, [:game_code])
  end
end
