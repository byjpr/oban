defmodule Oban.Integration.UniquenessTest do
  use Oban.Case

  import Ecto.Query

  alias Ecto.Multi

  @moduletag :integration

  defmodule UniqueWorker do
    use Oban.Worker, queue: :upsilon, unique: [period: 30]

    @impl Worker
    def perform(_job), do: :ok
  end

  setup do
    name = start_supervised_oban!(queues: [alpha: 5])

    {:ok, name: name}
  end

  property "preventing the same job from being enqueued multiple times", context do
    check all args <- arg_map(), runs <- integer(1..3), max_runs: 20 do
      fun = fn -> unique_insert!(context.name, args) end

      ids =
        1..runs
        |> Enum.map(fn _ -> Task.async(fun) end)
        |> Enum.map(&Task.await/1)
        |> Enum.map(fn %Job{id: id} -> id end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      assert 1 == length(ids)
    end
  end

  test "scoping uniqueness to particular fields", context do
    assert %Job{id: id_1} = unique_insert!(context.name, %{id: 1}, queue: "default")
    assert %Job{id: id_2} = unique_insert!(context.name, %{id: 2}, queue: "delta")
    assert %Job{id: ^id_2} = unique_insert!(context.name, %{id: 1}, unique: [fields: [:worker]])

    assert %Job{id: ^id_1} =
             unique_insert!(context.name, %{id: 3},
               queue: "default",
               unique: [fields: [:queue, :worker]]
             )

    assert %Job{id: ^id_2} =
             unique_insert!(context.name, %{id: 3},
               queue: "delta",
               unique: [fields: [:queue, :worker]]
             )

    assert count_jobs() == 2
  end

  test "scoping uniqueness to specific argument keys", context do
    assert %Job{id: id_1} = unique_insert!(context.name, %{id: 1, url: "https://a.co"})
    assert %Job{id: id_2} = unique_insert!(context.name, %{id: 2, url: "https://b.co"})

    assert %Job{id: ^id_1} =
             unique_insert!(context.name, %{id: 3, url: "https://a.co"}, unique: [keys: [:url]])

    assert %Job{id: ^id_2} =
             unique_insert!(context.name, %{id: 2, url: "https://a.co"}, unique: [keys: [:id]])

    assert %Job{id: ^id_2} = unique_insert!(context.name, %{"id" => 2}, unique: [keys: [:id]])

    assert count_jobs() == 2
  end

  test "scoping uniqueness by state", context do
    assert %Job{id: id_1} = unique_insert!(context.name, %{id: 1}, state: "available")
    assert %Job{id: id_2} = unique_insert!(context.name, %{id: 2}, state: "completed")
    assert %Job{id: id_3} = unique_insert!(context.name, %{id: 3}, state: "executing")
    assert %Job{id: id_4} = unique_insert!(context.name, %{id: 4}, state: "discarded")

    assert %Job{id: ^id_1} =
             unique_insert!(context.name, %{id: 1}, unique: [states: [:available]])

    assert %Job{id: ^id_2} =
             unique_insert!(context.name, %{id: 2}, unique: [states: [:available, :completed]])

    assert %Job{id: ^id_2} =
             unique_insert!(context.name, %{id: 2}, unique: [states: [:completed, :discarded]])

    assert %Job{id: ^id_3} =
             unique_insert!(context.name, %{id: 3}, unique: [states: [:completed, :executing]])

    assert %Job{id: ^id_4} =
             unique_insert!(context.name, %{id: 4}, unique: [states: [:completed, :discarded]])

    assert %Job{id: _id_4} = unique_insert!(context.name, %{id: 4}, unique: [period: 30])

    assert count_jobs() == 5
  end

  test "replace allows replacing the args for the same job id", context do
    assert %Job{id: id_1} = unique_insert!(context.name, %{id: 1, url: "https://a.co"})

    assert %Job{id: ^id_1, args: %{url: "https://b.co"}} =
             unique_insert!(
               context.name,
               %{id: 1, url: "https://b.co"},
               unique: [keys: [:id]],
               replace_args: true
             )
  end

  test "replace allows replacing job data for the same job id", context do
    now = DateTime.utc_now()
    in_one_minute = DateTime.add(now, 60, :second)
    in_two_minutes = DateTime.add(now, 120, :second)

    assert %Job{id: id_1} =
             unique_insert!(
               context.name,
               %{id: 1},
               scheduled_at: in_one_minute,
               tags: ["a"],
               priority: 3,
               max_attempts: 1
             )

    assert %Job{
             id: ^id_1,
             scheduled_at: ^in_two_minutes,
             tags: ["b"],
             priority: 2,
             max_attempts: 1
           } =
             unique_insert!(
               context.name,
               %{id: 1},
               unique: [keys: [:id]],
               scheduled_at: in_two_minutes,
               tags: ["b"],
               priority: 2,
               max_attempts: 3,
               replace: [:scheduled_at, :tags, :priority]
             )
  end

  test "scoping uniqueness by period", %{name: name} do
    now = DateTime.utc_now()
    two_minutes_ago = DateTime.add(now, -120, :second)
    five_minutes_ago = DateTime.add(now, -300, :second)
    two_years_ago = Map.put(now, :year, now.year - 2)
    one_year_in_seconds = 365 * 24 * 60 * 60

    assert %Job{id: _id} = unique_insert!(name, %{id: 1}, inserted_at: two_minutes_ago)
    assert %Job{id: _id} = unique_insert!(name, %{id: 2}, inserted_at: five_minutes_ago)
    assert %Job{id: _id} = unique_insert!(name, %{id: 3}, inserted_at: two_years_ago)

    assert %Job{id: id_1} = unique_insert!(name, %{id: 1}, unique: [period: 110])
    assert %Job{id: id_2} = unique_insert!(name, %{id: 2}, unique: [period: 290])
    assert %Job{id: id_3} = unique_insert!(name, %{id: 3}, unique: [period: one_year_in_seconds])

    assert %Job{id: ^id_1} = unique_insert!(name, %{id: 1}, unique: [period: 180])
    assert %Job{id: ^id_2} = unique_insert!(name, %{id: 2}, unique: [period: 400])
    assert %Job{id: ^id_3} = unique_insert!(name, %{id: 3}, unique: [period: :infinity])

    assert count_jobs() == 6
  end

  test "inserting unique jobs within a multi transaction", context do
    multi = Multi.new()
    multi = Oban.insert(context.name, multi, :job_1, UniqueWorker.new(%{id: 1}))
    multi = Oban.insert(context.name, multi, :job_2, UniqueWorker.new(%{id: 2}))
    multi = Oban.insert(context.name, multi, :job_3, UniqueWorker.new(%{id: 1}))
    assert {:ok, %{job_1: job_1, job_2: job_2, job_3: job_3}} = Repo.transaction(multi)

    assert job_1.id != job_2.id
    assert job_1.id == job_3.id

    assert count_jobs() == 2
  end

  def arg_map, do: map_of(arg_key(), arg_val())
  def arg_key, do: one_of([integer(), string(:ascii)])
  def arg_val, do: one_of([integer(), string(:ascii), list_of(integer())])

  defp unique_insert!(name, args, opts \\ []) do
    Oban.insert!(name, UniqueWorker.new(args, opts))
  end

  defp count_jobs do
    Job
    |> select([j], count(j.id))
    |> Repo.one()
  end
end
