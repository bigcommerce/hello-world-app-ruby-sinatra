# Bigcommerce Sample App: Hello World in Ruby and Sinatra

## App Registration
 - Create a trial shop on [Bigcommerce](https://www.bigcommerce.com/)
 - Go to the [developer portal](https://developer.bigcommerce.com/) and log in
 - Go to "My Apps" (linked in the navbar)
 - Click the button "Create an app", enter a name for the new app and then click the button "Create"
 - Go right to section 4 (Technical) in the app dialog and enter the following URLs:
   - *Auth Callback URL* - `https://<app hostname>/auth/bigcommerce/callback`
   - *Load Callback URL* - `https://<app hostname>/load`
   - *Uninstall Callback URL* - `https://<app hostname>/uninstall`
 - Enable the following permission scopes under *OAuth scopes*:
   - *Orders* - MODIFY
   - *Products* - MODIFY
   - *Customers* - MODIFY
   - *Content* - MODIFY
   - *Marketing* - MODIFY
   - *Information* - READ-ONLY
 - Finally, click `Save & Close` on the top right of the dialog

## App Setup

### Heroku

*Note: it is assumed that one already has a Heroku account, has the Heroku toolbelt installed, and has authenticated with the toolbelt*

 - Change to the directory this repo was cloned to: `cd <path to project>`
 - Create a new Heroku app: `heroku create <appname>`
 - Push the project to Heroku: `git push heroku master -u`
 - Copy `./.env-example` to `./.env`
 - Edit `.env`:
   - Set `BC_CLIENT_ID` and `BC_CLIENT_SECRET` to the values provided by Bigcommerce (in the developer portal the app has a link/icon labled `View Client ID`)
   - Set `APP_URL` to `https://<appname>.herokuapp.com`
   - Set `SESSION_SECRET` to some random string
 -  Add the `heroku-config` plugin: `heroku plugins:install git://github.com/ddollar/heroku-config.git`
 -  Push the local environment variables to heroku: `heroku config:push`

In the Bigcommerce developer portal the app's technical settings should have the following URLs:

 - *Auth Callback URL* - `https://<appname>.herokuapp.com/auth/bigcommerce/callback`
 - *Load Callback URL* - `https://<appname>.herokuapp.com/load`
 - *Uninstall Callback URL* - `https://<appname>.herokuapp.com/uninstall`

### Other

TBD

## App Install

Back in the trial store, go the `Apps` section and look for a section `My Drafts`. Find the app you just created and click it. A details dialog should appear with an `Install` button. Click it and the draft app should be added to your store.
