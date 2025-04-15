defmodule ConstellationWeb.HealthController do
  use ConstellationWeb, :controller

  @doc """
  Simple health check endpoint for Kubernetes probes.
  Returns a 200 OK status if the application is running.
  
  For more comprehensive health checks, you could add:
  - Database connectivity check
  - External API dependency checks
  - Memory/resource usage checks
  """
  def check(conn, _params) do
    # Basic check: Can the app respond?
    # You could add more comprehensive checks here if needed
    send_resp(conn, 200, "OK")
  end
end
