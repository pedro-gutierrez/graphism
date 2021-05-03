defmodule Graphism.Migrations do
  @moduledoc """
  A database migrations generator based on a
  Graphism schema
  """
  require Logger

  @migrations_dir Path.join([File.cwd!(), "priv/repo/migrations"])
  @migrations Path.join([@migrations_dir, "graphism_*.exs"])

  @doc """
  Generate migrations for the given schema. 

  """
  def generate(module: mod) do
    schema = mod.schema()

    migrations = existing_migrations()

    existing_migrations =
      read_migrations(migrations)
      |> reduce_migrations()

    last_migration_version = last_migration_version(migrations)

    schema_migration = migration_from_schema(schema)

    missing_migrations =
      missing_migrations(
        existing_migrations,
        schema_migration
      )

    write_migration(missing_migrations, last_migration_version + 1, dir: File.cwd!())
  end

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

  defp missing_migrations(existing, schema) do
    # New tables to be created
    tables_to_create = Map.keys(schema) -- Map.keys(existing)

    missing_migrations =
      Enum.reduce(tables_to_create, [], fn name, acc ->
        [create_table_migration(name, schema) | acc]
      end)

    # Old tables to be dropped
    tables_to_drop = Map.keys(existing) -- Map.keys(schema)

    missing_migrations =
      Enum.reduce(tables_to_drop, missing_migrations, fn name, acc ->
        [drop_table_migration(name) | acc]
      end)

    # Add the tables to be merged. We need to 
    # implement the same logic at the column level, for each table
    tables_to_merge = Map.keys(schema) -- Map.keys(schema) -- Map.keys(existing)

    Enum.reduce(tables_to_merge, missing_migrations, fn name, acc ->
      existing_columns = Map.keys(existing[name][:columns])
      schema_columns = Map.keys(schema[name][:columns])

      # columns to add
      columns_to_add =
        (schema_columns -- existing_columns)
        |> Enum.map(fn col ->
          column = schema[name][:columns][col]
          [column: col, type: column[:type], opts: column[:opts], action: :add]
        end)

      # columns to remove
      columns_to_remove = existing_columns -- schema_columns

      case length(columns_to_add) + length(columns_to_remove) do
        0 ->
          # If we dont have anything to do, then we skip the 
          # alter table migration altogether
          []

        _ ->
          [alter_table_migration(name, columns_to_add, columns_to_remove) | acc]
      end
    end)
    |> Enum.reverse()
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

  defp alter_table_migration(name, columns_to_add, columns_to_remove) do
    [
      table: name,
      action: :alter,
      columns:
        Enum.map(columns_to_add, fn col ->
          [column: col[:column], type: col[:type], opts: col[:opts], action: :add]
        end) ++
          Enum.map(columns_to_remove, fn col ->
            [column: col, action: :remove]
          end)
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

  defp reduce_migration([table: t, action: :drop, opts: _, columns: _], acc) do
    Map.drop(acc, [t])
  end

  defp reduce_migration([table: t, action: :create, opts: _, columns: cols], acc) do
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

  defp reduce_migration(
         [table: t, action: :alter, opts: _, columns: column_changes] = spec,
         acc
       ) do
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

  defp migration_version([]), do: 0

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
    |> Enum.reject(fn item -> item == [] end)
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
    |> Enum.reject(fn item -> item == [] end)
  end

  defp parse_migration({:defmodule, _, [{:__aliases__, _, migration}, _]}) do
    Logger.warn("Unable to parse migration #{Enum.join(migration, ".")}")
    []
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
    table_change(table, action, [], changes)
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
    table_change(table, action, [], [change])
  end

  defp parse_up(
         {action, _,
          [
            {:table, _, [table, opts]},
            [
              do: {:__block__, [], changes}
            ]
          ]}
       ) do
    table_change(table, action, opts, changes)
  end

  defp parse_up(
         {action, _,
          [
            {:table, _, [table]}
          ]}
       ) do
    table_change(table, action, [], [])
  end

  defp parse_up(other) do
    Logger.warn(
      "Unable to parse migration code #{inspect(other)}: #{
        other |> Macro.to_string() |> Code.format_string!()
      }"
    )

    []
  end

  defp table_name(n) when is_binary(n), do: String.to_atom(n)
  defp table_name(n) when is_atom(n), do: n

  defp table_change(table, action, opts, columns) do
    columns =
      columns
      |> Enum.map(&column_change(&1))
      |> Enum.reduce(%{}, fn col, map ->
        Map.put(map, col[:column], %{
          type: col[:type],
          opts: col[:opts],
          action: col[:action]
        })
      end)

    table = table_name(table)

    [table: table, action: action, opts: opts, columns: columns]
  end

  defp column_change({:timestamps, _, _}) do
    [meta: :timestamps, action: :create]
  end

  defp column_change({action, _, [name, type]}) do
    [column: name, type: type, opts: [], action: action]
  end

  defp column_change({action, _, [name, type, opts]}) do
    [column: name, type: type, opts: opts, action: action]
  end

  defp column_change({action, _, [name]}) do
    [column: name, action: action]
  end

  defp write_migration([], _, _) do
    IO.puts("No migrations to write")
  end

  defp write_migration(migration, version, opts) do
    module_name = [:Graphism, :Migration, String.to_atom("V#{version}")]
    up = Enum.map(migration, &quote_migration(&1))

    code =
      module_name
      |> migration_module(up)
      |> Macro.to_string()
      |> Code.format_string!()

    path = Path.join([opts[:dir], "priv", "repo", "migrations", "graphism_v#{version}.exs"])
    File.write!(path, code)
    IO.puts("Written #{path}")
  end

  defp migration_module(name, up) do
    {:defmodule, [line: 1],
     [
       {:__aliases__, [line: 1], name},
       [
         do:
           {:__block__, [],
            [
              {:use, [line: 1], [{:__aliases__, [line: 1], [:Ecto, :Migration]}]},
              {:def, [line: 1],
               [
                 {:up, [line: 1], nil},
                 [
                   do: {:__block__, [], up}
                 ]
               ]},
              {:def, [line: 1],
               [
                 {:down, [line: 1], nil},
                 [do: []]
               ]}
            ]}
       ]
     ]}
  end

  defp quote_migration(table: table, action: :create, columns: cols) do
    {:create, [line: 1],
     [
       {:table, [line: 1], [table, [primary_key: false]]},
       [
         do: {:__block__, [], Enum.map(cols, &column_change_ast(&1))}
       ]
     ]}
  end

  defp quote_migration(table: table, action: :alter, columns: cols) do
    {:alter, [line: 1],
     [
       {:table, [line: 1], [table]},
       [
         do: {:__block__, [], Enum.map(cols, &column_change_ast(&1))}
       ]
     ]}
  end

  defp quote_migration(table: table, action: :drop) do
    {:drop, [line: 1],
     [
       {:table, [line: 1], [table]}
     ]}
  end

  # Given a column change, generate the AST that will be
  # included in a migration, inside a create/alter table block
  defp column_change_ast(column: name, type: type, opts: _, action: :add) do
    {:add, [], [name, type]}
  end

  # Translates a drop table change into the AST
  # that will be included in a migration, inside an alter
  # table block
  defp column_change_ast(column: name, action: :remove) do
    {:remove, [], [name]}
  end
end
