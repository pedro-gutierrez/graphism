defmodule(Graphism.Migration.V2) do
  use(Ecto.Migration)

  def(up) do
    drop_if_exists(table(:permissions))
  end

  def(down) do
    []
  end
end