require 'rails_helper'
require 'huginn_agent/spec_helper'

describe Agents::GitAgent do
  before(:each) do
    @valid_options = Agents::GitAgent.new.default_options
    @checker = Agents::GitAgent.new(:name => "GitAgent", :options => @valid_options)
    @checker.user = users(:bob)
    @checker.save!
  end

  pending "add specs here"
end
