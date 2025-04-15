defmodule ConstellationWeb.RulesController do
  use ConstellationWeb, :controller

  @doc """
  Renders the game rules page
  """
  def index(conn, _params) do
    render(conn, :index)
  end
end
