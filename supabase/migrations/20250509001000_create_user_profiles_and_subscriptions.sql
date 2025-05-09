-- Create public schema tables for user profiles and subscriptions
-- Migration: 20250509001000_create_user_profiles_and_subscriptions.sql

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-------------------------------------------------------
-- PROFILES TABLE
-------------------------------------------------------
-- Create profiles table that extends auth.users
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID REFERENCES auth.users(id) PRIMARY KEY,
  username TEXT UNIQUE,
  full_name TEXT,
  avatar_url TEXT,
  website TEXT,
  
  -- Auditing fields
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Add comment to profiles table
COMMENT ON TABLE public.profiles IS 'User profile information extending the auth.users table';

-- Create trigger to update the updated_at column
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_profiles_updated_at
BEFORE UPDATE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-------------------------------------------------------
-- SUBSCRIPTIONS TABLE
-------------------------------------------------------
-- Create subscription plans enum
CREATE TYPE subscription_plan_type AS ENUM ('free', 'basic', 'premium', 'enterprise');

-- Create subscription status enum
CREATE TYPE subscription_status_type AS ENUM ('active', 'canceled', 'expired', 'trial', 'past_due');

-- Create subscriptions table
CREATE TABLE IF NOT EXISTS public.subscriptions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  
  -- Subscription details
  plan subscription_plan_type NOT NULL DEFAULT 'free',
  status subscription_status_type NOT NULL DEFAULT 'active',
  price_paid DECIMAL(10, 2),
  currency TEXT DEFAULT 'USD',
  
  -- Subscription dates
  start_date TIMESTAMPTZ NOT NULL DEFAULT now(),
  end_date TIMESTAMPTZ,
  trial_end_date TIMESTAMPTZ,
  
  -- Payment info
  payment_provider TEXT, -- e.g., 'stripe', 'paypal'
  payment_id TEXT, -- external ID from payment provider
  
  -- Auditing fields
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  
  -- We'll use a partial index instead of a WHERE clause in the constraint
  CONSTRAINT unique_user_id UNIQUE (user_id)
);

-- Add comment to subscriptions table
COMMENT ON TABLE public.subscriptions IS 'User subscription records with plan details and payment history';

-- Create indexes for improved query performance
CREATE INDEX idx_subscriptions_user_id ON public.subscriptions(user_id);
CREATE INDEX idx_subscriptions_status ON public.subscriptions(status);
CREATE INDEX idx_subscriptions_end_date ON public.subscriptions(end_date);

-- Create a partial index to enforce the rule that a user can only have one active subscription
CREATE UNIQUE INDEX idx_user_active_subscription 
  ON public.subscriptions(user_id) 
  WHERE (status = 'active' OR status = 'trial');

-- Create trigger to update the updated_at column
CREATE TRIGGER update_subscriptions_updated_at
BEFORE UPDATE ON public.subscriptions
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-------------------------------------------------------
-- SUBSCRIPTION FEATURES TABLE (for feature flagging)
-------------------------------------------------------
-- Create subscription features table to track what features are available in each plan
CREATE TABLE IF NOT EXISTS public.subscription_features (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  plan subscription_plan_type NOT NULL,
  feature_name TEXT NOT NULL,
  feature_value JSONB,
  
  -- Auditing fields
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  
  -- Constraint: each feature can only be defined once per plan
  CONSTRAINT unique_plan_feature UNIQUE (plan, feature_name)
);

-- Add comment to subscription_features table
COMMENT ON TABLE public.subscription_features IS 'Features available for each subscription plan type';

-- Create trigger to update the updated_at column
CREATE TRIGGER update_subscription_features_updated_at
BEFORE UPDATE ON public.subscription_features
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-------------------------------------------------------
-- SECURITY POLICIES (RLS)
-------------------------------------------------------
-- Enable Row Level Security on profiles
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Profile policies
CREATE POLICY "Users can view their own profile"
  ON public.profiles
  FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Users can update their own profile"
  ON public.profiles
  FOR UPDATE
  USING (auth.uid() = id);

-- Enable Row Level Security on subscriptions
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

-- Subscription policies
CREATE POLICY "Users can view their own subscriptions"
  ON public.subscriptions
  FOR SELECT
  USING (auth.uid() = user_id);

-- Enable Row Level Security on subscription_features
ALTER TABLE public.subscription_features ENABLE ROW LEVEL SECURITY;

-- Subscription features policies - all users can view
CREATE POLICY "Users can view all subscription features"
  ON public.subscription_features
  FOR SELECT
  TO authenticated
  USING (true);

-------------------------------------------------------
-- FUNCTIONS & TRIGGERS
-------------------------------------------------------
-- Create a function to automatically create a profile when a new user signs up
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, username, avatar_url)
  VALUES (
    NEW.id,
    NEW.email, -- Default username to email
    'https://gravatar.com/avatar/' || md5(lower(trim(NEW.email))) || '?d=mp'
  );
  
  -- Also create a free subscription
  INSERT INTO public.subscriptions (user_id, plan, status)
  VALUES (NEW.id, 'free', 'active');
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger the function every time a user is created
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-------------------------------------------------------
-- INSERT STARTER DATA
-------------------------------------------------------
-- Insert default subscription feature definitions
INSERT INTO public.subscription_features (plan, feature_name, feature_value)
VALUES 
  ('free', 'max_projects', '2'),
  ('free', 'storage_gb', '1'),
  ('free', 'api_rate_limit', '100'),
  
  ('basic', 'max_projects', '10'),
  ('basic', 'storage_gb', '5'),
  ('basic', 'api_rate_limit', '500'),
  
  ('premium', 'max_projects', '50'),
  ('premium', 'storage_gb', '20'),
  ('premium', 'api_rate_limit', '2000'),
  
  ('enterprise', 'max_projects', 'null'), -- unlimited
  ('enterprise', 'storage_gb', '100'),
  ('enterprise', 'api_rate_limit', '5000'),
  ('enterprise', 'dedicated_support', 'true');
