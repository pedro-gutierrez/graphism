defmodule Graphism.Repo do
  use Ecto.Repo,
    otp_app: :graphism,
    adapter: Ecto.Adapters.Postgres
end
