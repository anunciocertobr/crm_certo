# frozen_string_literal: true

# Modulos do curso, na area do criador. Deletar um modulo leva as aulas junto —
# e a confirmacao e no frontend, porque no backend a perda de dados nao tem como
# ser desfeita.
class Api::V1::Creator::ModulesController < Api::V1::BaseController
  include CurrentCreator

  before_action :set_course
  before_action :set_module, only: %i[update destroy]

  def create
    mod = @course.course_modules.new(module_params)
    authorize @course, :update?

    if mod.save
      @course.recalculate_stats!
      success_response(data: serialize_module(mod), message: 'Module created successfully', status: :created)
    else
      validation_error(mod)
    end
  end

  def update
    authorize @course, :update?

    if @module.update(module_params)
      @course.recalculate_stats!
      success_response(data: serialize_module(@module), message: 'Module updated successfully')
    else
      validation_error(@module)
    end
  end

  def destroy
    authorize @course, :update?
    @module.destroy!
    @course.recalculate_stats!

    success_response(data: { id: @module.id }, message: 'Module deleted successfully')
  end

  private

  def set_course
    @course = current_creator.courses.find_by!(slug: params[:course_slug])
  end

  def set_module
    @module = @course.course_modules.find(params[:id])
  end

  def module_params
    params.require(:course_module).permit(:title, :position)
  end

  def serialize_module(mod)
    {
      id: mod.id,
      title: mod.title,
      position: mod.position,
      duration_seconds: mod.duration_seconds,
      lessons: mod.course_lessons.map { |lesson| { id: lesson.id, title: lesson.title, position: lesson.position } }
    }
  end
end
