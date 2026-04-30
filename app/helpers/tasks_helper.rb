module TasksHelper
  # One badge style per TaskStatus#label. Centralising avoids leaking
  # color tokens into views and keeps the presenter / view contract tight.
  STATUS_BADGE_CLASSES = {
    TaskStatus::QUEUED       => "bg-amber-50 text-amber-800 ring-amber-200",
    TaskStatus::RUNNING      => "bg-blue-50 text-blue-800 ring-blue-200",
    TaskStatus::RETRYING     => "bg-indigo-50 text-indigo-800 ring-indigo-200",
    TaskStatus::DONE         => "bg-emerald-50 text-emerald-800 ring-emerald-200",
    TaskStatus::FAILED       => "bg-rose-50 text-rose-800 ring-rose-200",
    TaskStatus::CANCELLED    => "bg-slate-100 text-slate-700 ring-slate-200",
    TaskStatus::NEEDS_REVIEW => "bg-yellow-50 text-yellow-900 ring-yellow-300",
    TaskStatus::BLOCKED      => "bg-rose-50 text-rose-800 ring-rose-200"
  }.freeze

  # Accepts a TaskStatus presenter so views never have to reach past it
  # for the label. Falls back to neutral styling for unknown labels so a
  # new state never crashes a rendered page.
  def status_badge(status)
    label   = status.label
    classes = STATUS_BADGE_CLASSES.fetch(label, "bg-slate-100 text-slate-700 ring-slate-200")
    tag.span(label.to_s.tr("_", " "),
             class: "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium ring-1 ring-inset #{classes}")
  end
end
