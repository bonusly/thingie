Rails.application.routes.draw do
  get "up", to: "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :v1 do
      resource :me, only: %i[show update], controller: :me

      resources :tasks do
        member do
          post :complete
          post :reopen
          post :archive
          post :assign
        end
        resources :comments, only: %i[index create], controller: "tasks/comments"
      end

      resources :comments, only: %i[update destroy]

      resources :draft_tasks do
        member do
          post :mark_ready
          post :release
          post :attach
          post :detach
          post :send_now
        end
      end

      resources :lists do
        member do
          post :deliver
          post :archive
          post :restore
        end
        resources :comments, only: %i[index create], controller: "lists/comments"
        resources :share_links, only: %i[index create destroy], controller: "lists/share_links"
      end

      resources :labels, except: :show

      resource :points, only: :show, controller: :points do
        get :ledger
      end

      resources :notifications, only: %i[index show] do
        member { post :mark_read }
        collection { post :mark_all_read }
      end

      resources :connector_accounts, only: %i[index create destroy] do
        member do
          post :sync
          post :pause
          post :resume
        end
        resources :external_items, only: :index, controller: "connector_accounts/external_items"
      end

      resources :external_items, only: [] do
        member { post :import }
      end

              resources :memberships, only: %i[index update destroy]
              resources :webhooks

        get "search", to: "search#index"
      get "search/routes", to: "search#routes"
    end
  end

  namespace :admin do
    resources :companies, only: %i[index show update] do
      member do
        post :suspend
        post :unsuspend
      end
    end
    resource :stats, only: :show
    resource :route_index, only: %i[show create]
  end

  scope module: :public do
    get "s/:token", to: "share_pages#show", as: :share_page
  end

  mount Sidekiq::Web => "/sidekiq" if defined?(Sidekiq::Web)
end
