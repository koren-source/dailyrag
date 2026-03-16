defmodule DailyRag.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: DailyRag.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: DailyRag.Supervisor)
  end
end
