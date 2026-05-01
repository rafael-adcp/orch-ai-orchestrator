// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// Persist the browser's IANA timezone in a cookie so the server can render
// times in the correct zone without a client-side rewrite.
const tz = Intl.DateTimeFormat().resolvedOptions().timeZone
if (tz && document.cookie.indexOf("tz=" + tz) === -1) {
  document.cookie = "tz=" + encodeURIComponent(tz) + ";path=/;max-age=31536000;SameSite=Lax"
}
