defmodule GraphismWeb.Router do
  use Phoenix.Router

  forward "/api", Absinthe.Plug, schema: GraphismWeb.Schema

  forward "/graphiql", Absinthe.Plug.GraphiQL,
    schema: GraphismWeb.Schema,
    interface: :simple
end
