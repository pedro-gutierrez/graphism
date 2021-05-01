defmodule GraphismWeb.Schema do
  use Graphism

  entity :superUser do
    attribute(:id, :id)
    attribute(:email, :string, unique: true)
    attribute(:first, :string)
    attribute(:last, :string)

    relation(:roles, :has_many, :role)
  end

  entity :role do
    attribute(:id, :id)
    attribute(:name, :string, unique: true)
  end
end
