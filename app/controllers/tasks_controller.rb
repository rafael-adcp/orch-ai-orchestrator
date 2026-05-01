class TasksController < ApplicationController
  def index
    set_tasks_list
  end

  def show
    @task = AiTask.find(params[:id])
  end

  def new
    pre = params.permit(ai_task: [ :repo_path, :prompt, :model, :effort, :docker_cmd, :priority, :recurring_interval_hours ])
    @task = AiTask.new(pre.fetch(:ai_task, {}))
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
    task.retry!
    redirect_to task_path(task), notice: "re-queued"
  end

  def cancel
    task = AiTask.find(params[:id])
    task.cancel!
    redirect_to task_path(task), notice: "cancelled"
  end

  def destroy
    task = AiTask.find(params[:id])
    result = TaskPurge.delete(task)
    if result.deleted?
      redirect_to tasks_path, notice: "deleted #{task.id}"
    else
      redirect_to task_path(task), alert: "cannot delete: #{result.reason}"
    end
  end

  def purge
    TaskPurge.sweep
    set_tasks_list
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace("tasks-list", partial: "tasks/tasks_list") }
      format.html { redirect_to tasks_path }
    end
  end

  def log
    task = AiTask.find(params[:id])
    render plain: task.log_text || "(no log yet)"
  end

  private

  def task_params
    params.require(:ai_task).permit(:repo_path, :prompt, :model, :effort, :docker_cmd, :priority, :recurring_interval_hours)
  end

  def set_tasks_list
    per_page  = Rails.application.config.orchestrator[:tasks_per_page]
    @page     = [ params[:page].to_i, 1 ].max
    @tasks    = AiTask.recent.offset((@page - 1) * per_page).limit(per_page + 1)
    @has_next = @tasks.size > per_page
    @tasks    = @tasks.first(per_page)
  end
end
