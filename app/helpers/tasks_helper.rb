module TasksHelper
  # Map an AiTask status to the badge classes used in views. Centralizing
  # avoids scattering color tokens across templates and makes it trivial to
  # restyle later (or swap for a real component library).
  STATUS_BADGE_CLASSES = {
    AiTask::PENDING   => "bg-amber-50 text-amber-800 ring-amber-200",
    AiTask::RUNNING   => "bg-blue-50 text-blue-800 ring-blue-200",
    AiTask::DONE      => "bg-emerald-50 text-emerald-800 ring-emerald-200",
    AiTask::FAILED    => "bg-rose-50 text-rose-800 ring-rose-200",
    AiTask::CANCELLED => "bg-slate-100 text-slate-700 ring-slate-200"
  }.freeze

  def status_badge(status)
    classes = STATUS_BADGE_CLASSES.fetch(status, "bg-slate-100 text-slate-700 ring-slate-200")
    tag.span(status, class: "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium ring-1 ring-inset #{classes}")
  end
end
