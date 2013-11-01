class Source < ActiveRecord::Base
  ##
  # Associations
  has_many :data
  has_many :events
  has_many :change_logs
  belongs_to :source_type
  belongs_to :user

  ##
  # Attributes
  # attr_accessible :description, :location, :source_type_id, :user_id, :notes

  ##
  # Callbacks

  ##
  # Concerns
  include Loggable, Indexable, Associatable, Deletable

  ##
  # Database Settings

  ##
  # Scopes
  scope :search, lambda { |term| search_scope([:id, :location, :description, :notes], term) }

  ##
  # Validations
  validates_presence_of :location

  ##
  # Class Methods

  ##
  # Instance Methods
  def type=(type_params)
    set_immutable(SourceType, type_params)
  end

  def source_user=(user_params)
    set_immutable(User, user_params)
  end

  private


end