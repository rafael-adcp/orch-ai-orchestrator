import { Controller } from "@hotwired/stimulus"

// Controls the bulk-action bar above the tasks table: toggles every row
// when the header checkbox flips, keeps the count + visibility in sync,
// and lets the form submit only the checked ids.
export default class extends Controller {
  static targets = ["all", "row", "bar", "count"]

  toggleAll(event) {
    this.rowTargets.forEach((cb) => (cb.checked = event.target.checked))
    this.refresh()
  }

  toggleRow() {
    this.refresh()
  }

  refresh() {
    const checked = this.rowTargets.filter((cb) => cb.checked)
    this.barTarget.classList.toggle("hidden", checked.length === 0)
    this.countTarget.textContent = checked.length
    if (this.hasAllTarget) {
      this.allTarget.checked =
        checked.length > 0 && checked.length === this.rowTargets.length
      this.allTarget.indeterminate =
        checked.length > 0 && checked.length < this.rowTargets.length
    }
  }
}
