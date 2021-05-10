defmodule(Graphism.Migration.V2) do
  use(Ecto.Migration)

  def(up) do
    alter(table(:permissions)) do
      add(:role_id, references(:roles, type: :uuid), null: false)
    end
  end

  def(down) do
    []
  end
end