defmodule Graphism do
  @moduledoc """
  Graphism keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  defmacro __using__(_opts \\ []) do
    _existing_migrations = read_migrations()

    Module.register_attribute(__CALLER__.module, :schema,
      accumulate: true,
      persist: true
    )

    quote do
      @before_compile unquote(__MODULE__)
      import unquote(__MODULE__), only: :macros
      use Absinthe.Schema
    end
  end

  defmacro __before_compile__(_) do
    schema = Module.get_attribute(__CALLER__.module, :schema)

    api_modules =
      Enum.map(schema, fn e ->
        api_module(e, schema, caller: __CALLER__)
      end)

    objects =
      Enum.map(schema, fn e ->
        graphql_object(e, schema)
      end)

    queries =
      quote do
        query do
          unquote do
            Enum.flat_map(schema, fn e ->
              graphql_queries(e, schema)
            end)
          end
        end
      end

    [api_modules, objects, queries]
  end

  defmacro entity(name, _attrs \\ [], do: block) do
    attrs = attributes_from(block)
    rels = relations_from(block)

    entity =
      [name: name, attributes: attrs, relations: rels]
      |> with_plural()
      |> with_schema_module()

    Module.put_attribute(__CALLER__.module, :schema, entity)

    block
  end

  defmacro attribute(_name, _type, _attrs \\ []) do
  end

  defmacro relation(_name, _cardinality, _target, _attrs \\ []) do
  end

  defp with_plural(entity) do
    case entity[:plural] do
      nil ->
        Keyword.put(entity, :plural, String.to_atom("#{entity[:name]}s"))

      _ ->
        entity
    end
  end

  defp with_schema_module(entity) do
    Keyword.put(
      entity,
      :schema_module,
      Module.concat([
        entity[:name],
        :schema
      ])
    )
  end

  defp api_module(e, _schema, _opts) do
    quote do
      defmodule unquote(e[:schema_module]) do
        use Ecto.Schema
        import Ecto.Changeset

        schema unquote("#{e[:plural]}") do
          unquote do
            e[:attributes]
            |> Enum.reject(fn attr -> attr[:name] == :id end)
            |> Enum.map(fn attr ->
              quote do
                Ecto.Schema.field(unquote(attr[:name]), unquote(attr[:type]))
              end
            end)
          end

          timestamps()
        end
      end
    end
  end

  defp graphql_object(e, _schema) do
    quote do
      object unquote(e[:name]) do
        unquote do
          Enum.map(e[:attributes], fn attr ->
            quote do
              field unquote(attr[:name]), unquote(attr[:type])
            end
          end)
        end
      end
    end
  end

  defp graphql_queries(e, schema) do
    [
      graphql_query_list_all(e, schema),
      graphql_query_find_by_id(e, schema),
      graphql_query_find_by_unique_fields(e, schema)
    ]
  end

  defp graphql_query_list_all(e, _schema) do
    quote do
      @desc "List all " <> unquote("#{e[:plural]}")
      field unquote(e[:plural]), list_of(unquote(e[:name])) do
        resolve(fn _, _, _ ->
          {:ok, []}
        end)
      end
    end
  end

  defp graphql_query_find_by_id(e, _schema) do
    quote do
      @desc "Find a single " <> unquote("#{e[:name]}") <> " given its id"
      field unquote(String.to_atom("get_#{e[:name]}_by_id")),
            unquote(e[:name]) do
        resolve(fn _, _, _ ->
          {:ok, []}
        end)
      end
    end
  end

  defp graphql_query_find_by_unique_fields(_e, _schema) do
    []
  end

  defp attributes_from({:__block__, [], attrs}) do
    attrs
    |> Enum.map(fn
      {:attribute, _, attr} ->
        attribute(attr)

      _ ->
        nil
    end)
    |> Enum.reject(fn attr -> attr == nil end)
  end

  defp attribute([name, type]), do: [name: name, type: type, opts: []]
  defp attribute([name, type, opts]), do: [name: name, type: type, opts: opts]

  defp relations_from({:__block__, [], attrs}) do
    attrs
    |> Enum.map(fn
      {:relation, _, rel} ->
        relation(rel)

      _ ->
        nil
    end)
    |> Enum.reject(fn rel -> rel == nil end)
  end

  defp relation([name, c, e]), do: [name: name, cardinality: c, entity: e]

  @migrations_dir Path.join([File.cwd!(), "priv/repo/migrations"])
  @migrations Path.join([@migrations_dir, "graphism_*.exs"])

  defp read_migrations() do
    @migrations
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&File.read!(&1))
    |> Enum.map(&Code.string_to_quoted!(&1))
    |> Enum.flat_map(&parse_migration(&1))
    |> IO.inspect()
  end

  defp parse_migration(
         {:defmodule, _,
          [
            {:__aliases__, _, _},
            [
              do:
                {:__block__, [],
                 [
                   {:use, _, [{:__aliases__, _, [:Ecto, :Migration]}]},
                   {:def, _,
                    [
                      {:up, _, nil},
                      [
                        do: {:__block__, [], up}
                      ]
                    ]},
                   {:def, _,
                    [
                      {:down, _, nil},
                      [do: _]
                    ]}
                 ]}
            ]
          ]}
       ) do
    parse_ups(up)
  end

  defp parse_migration(
         {:defmodule, _,
          [
            {:__aliases__, _, _},
            [
              do:
                {:__block__, [],
                 [
                   {:use, _, [{:__aliases__, _, [:Ecto, :Migration]}]},
                   {:def, _,
                    [
                      {:up, _, nil},
                      [
                        do: up
                      ]
                    ]},
                   {:def, _,
                    [
                      {:down, _, nil},
                      [do: _]
                    ]}
                 ]}
            ]
          ]}
       ) do
    [parse_up(up)]
  end

  defp parse_ups(ups) do
    Enum.map(ups, &parse_up(&1))
  end

  defp parse_up(
         {action, _,
          [
            {:table, _, [table]},
            [
              do: {:__block__, [], actions}
            ]
          ]}
       ) do
    [table: String.to_atom(table), action: action, columns: Enum.map(actions, &table_action(&1))]
  end

  defp parse_up(
         {action, _,
          [
            {:table, _, [table]},
            [
              do: column_action
            ]
          ]}
       ) do
    [table: String.to_atom(table), action: action, columns: [table_action(column_action)]]
  end

  defp table_action({action, _, [name, type]}) do
    [column: name, type: type, ops: [], action: action]
  end

  defp table_action({action, _, [name, type, ops]}) do
    [column: name, type: type, ops: ops, action: action]
  end

  defp table_action({action, _, [name]}) do
    [column: name, action: action]
  end

  defp table_action({:timestamps, _, _}) do
    [meta: :timestamps, action: :create]
  end
end
