defmodule Constellation.Repo do
  use Ecto.Repo,
    otp_app: :constellation,
    adapter: Ecto.Adapters.Postgres
end
