class TasksController < ApplicationController
  def index
    @tasks = AiTask.recent.limit(100)
  end

  def show
    @task = AiTask.find(params[:id])
  end

  def new
    @task = AiTask.new
  end

  def create
    @task = AiTask.new(task_params)
    if @task.save
      @task.enqueue!
      redirect_to task_path(@task), notice: "queued #{@task.id}"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def retry
    task = AiTask.find(params[:id])
    task.update!(status: "pending", error: nil, started_at: nil, finished_at: nil)
    task.enqueue!
    redirect_to task_path(task), notice: "re-queued"
  end

  def cancel
    task = AiTask.find(params[:id])
    task.update!(status: "cancelled") if task.status == "pending"
    redirect_to task_path(task), notice: "cancelled"
  end

  def log
    task = AiTask.find(params[:id])
    render plain: task.log_text || "(no log yet)"
  end

  private

  def task_params
    params.require(:ai_task).permit(:repo_path, :prompt, :branch, :model, :docker_cmd, :priority)
  end
end
