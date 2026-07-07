from django.urls import path

from . import views

# The frontend isn't fully consistent about trailing slashes across its own
# calls (balance/ has one, initiate doesn't), so every route below is
# registered both ways rather than trying to make the frontend consistent.
urlpatterns = [
    path("balance/<str:device_id>", views.balance_lookup),
    path("balance/<str:device_id>/", views.balance_lookup),
    path("initiate", views.initiate),
    path("initiate/", views.initiate),
    path("esewa/form/<str:order_id>", views.esewa_form),
    path("esewa/form/<str:order_id>/", views.esewa_form),
    path("esewa/return", views.esewa_return),
    path("esewa/return/", views.esewa_return),
    path("khalti/return", views.khalti_return),
    path("khalti/return/", views.khalti_return),
]
