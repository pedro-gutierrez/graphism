defmodule Graphism do
  @moduledoc """
  Graphism keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  defmacro __using__(_opts \\ []) do
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

    migrations = existing_migrations()

    existing_migrations =
      read_migrations(migrations)
      |> reduce_migrations()

    last_migration_version = last_migration_version(migrations)

    schema_migration = migration_from_schema(schema)

    generate_missing_migrations(
      existing_migrations,
      schema_migration,
      last_migration_version
    )

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

  defp migration_from_schema(schema) do
    Enum.reduce(schema, %{}, fn entity, acc ->
      migration_from_entity(entity, schema, acc)
    end)
  end

  defp migration_from_entity(e, _, acc) do
    # convert entity attributes as simple columns 
    # to be added to the table migrations
    m =
      Enum.reduce(e[:attributes], %{}, fn attr, m ->
        Map.put(m, attr[:name], %{
          type: attr[:type],
          opts: attr[:opts]
        })
      end)

    # also convert entity relations as 
    # foreign keys in the table migration

    table_name =
      e[:plural]
      |> Atom.to_string()
      |> Recase.to_snake()
      |> String.to_atom()

    Map.put(acc, table_name, %{
      columns: m
    })
  end

  defp generate_missing_migrations(existing, schema, last_version) do
    tables_to_create = Map.keys(schema) -- Map.keys(existing)

    missing_migrations =
      Enum.reduce(tables_to_create, [], fn name, acc ->
        [create_table_migration(name, schema) | acc]
      end)

    tables_to_drop = Map.keys(existing) -- Map.keys(schema)

    missing_migrations =
      Enum.reduce(tables_to_drop, missing_migrations, fn name, acc ->
        [drop_table_migration(name) | acc]
      end)

    missing_migrations = Enum.reverse(missing_migrations)

    IO.inspect(
      existing: existing,
      schema: schema,
      last_version: last_version,
      missing: missing_migrations
    )
  end

  defp create_table_migration(name, schema) do
    [
      table: name,
      action: :create,
      columns:
        Enum.map(schema[name][:columns], fn {col, spec} ->
          migration_from_column(col, spec, :add)
        end)
    ]
  end

  defp drop_table_migration(name) do
    [
      table: name,
      action: :drop
    ]
  end

  defp migration_from_column(col, spec, action) do
    [column: col, type: spec[:type], opts: spec[:opts], action: action]
  end

  defp existing_migrations() do
    @migrations
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&File.read!(&1))
    |> Enum.map(&Code.string_to_quoted!(&1))
  end

  defp read_migrations(migrations) do
    migrations
    |> Enum.flat_map(&parse_migration(&1))
  end

  defp reduce_migrations(migrations) do
    migrations
    |> Enum.reduce(%{}, &reduce_migration(&1, &2))
  end

  defp reduce_migration([table: t, action: :drop, columns: _], acc) do
    Map.drop(acc, [t])
  end

  defp reduce_migration([table: t, action: :create, columns: cols], acc) do
    # Since this is a create table migration,
    # all columns must be present. We just need to remove the 
    # action on each column
    cols =
      Enum.reduce(cols, %{}, fn {name, spec}, acc ->
        Map.put(acc, name, Map.drop(spec, [:action]))
      end)

    # Then replace the resulting table columns
    # in our accumulator
    Map.put(acc, t, %{columns: cols})
  end

  defp reduce_migration([table: t, action: :alter, columns: column_changes] = spec, acc) do
    table = Map.get(acc, t)

    # Ensure the table is already present in our current
    # set of migrations. Otherwise, this is a bug. Maybe the migrations
    # are not properly sorted, or there is a missing migration
    unless table do
      raise "Error reading migrations. Trying to alter non existing table: #{inspect(spec)}"
    end

    # Reduce the column changeset on top of the existing columns
    # We either drop columns, add new ones, or renaming existing or 
    # change their types
    new_columns =
      column_changes
      |> Enum.reduce(table[:columns], fn {col, change}, cols ->
        case change[:action] do
          :remove ->
            Map.drop(cols, [col])

          :add ->
            Map.put(cols, col, %{
              type: change[:type],
              opts: change[:opts]
            })
        end
      end)

    # Then replace the resulting table columns 
    # in our accumulator
    put_in(acc, [t, :columns], new_columns)
  end

  defp last_migration_version(migrations) do
    migrations
    |> Enum.take(-1)
    |> migration_version()
  end

  defp migration_version([
         {:defmodule, _,
          [
            {:__aliases__, _, module},
            _
          ]}
       ]) do
    [version] =
      module
      |> Enum.take(-1)

    version =
      version
      |> Atom.to_string()
      |> String.replace_prefix("V", "")
      |> String.to_integer()

    version
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
    Enum.map(up, &parse_up(&1))
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

  defp parse_up(
         {action, _,
          [
            {:table, _, [table]},
            [
              do: {:__block__, [], changes}
            ]
          ]}
       ) do
    columns =
      changes
      |> Enum.map(&column_change(&1))
      |> Enum.reduce(%{}, &into_columns_map(&1, &2))

    [table: String.to_atom(table), action: action, columns: columns]
  end

  defp parse_up(
         {action, _,
          [
            {:table, _, [table]},
            [
              do: change
            ]
          ]}
       ) do
    columns =
      change
      |> column_change()
      |> into_columns_map(%{})

    [table: String.to_atom(table), action: action, columns: columns]
  end

  defp into_columns_map(col, map) do
    Map.put(map, col[:column], %{
      type: col[:type],
      opts: col[:opts],
      action: col[:action]
    })
  end

  defp column_change({:timestamps, _, _}) do
    [meta: :timestamps, action: :create]
  end

  defp column_change({action, _, [name, type]}) do
    [column: name, type: type, ops: [], action: action]
  end

  defp column_change({action, _, [name, type, ops]}) do
    [column: name, type: type, ops: ops, action: action]
  end

  defp column_change({action, _, [name]}) do
    [column: name, action: action]
  end
end
