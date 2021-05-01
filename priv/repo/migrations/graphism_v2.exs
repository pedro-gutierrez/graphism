defmodule Graphism.Migration.V2 do
  use Ecto.Migration

  def up do
    alter table("weather") do
      remove :city
    end
  end

  def down do
    alter table("weather") do
      add :city, :string, size: 40
    end
  end
end
